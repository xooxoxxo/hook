import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import RelayCore
import os

/// Holds setup material only while the authenticated sheet is visible. Never log this object.
@MainActor public final class PhonePairingController: ObservableObject {
    public enum Failure: Error, LocalizedError {
        case unavailable, cancelled, credentials, image
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Connect to an HTTPS Pond before pairing a phone."
            case .cancelled: "Setup was cancelled."
            case .credentials: "Hook couldn't read a valid Pond login. Check the connection and try again."
            case .image: "Hook couldn't create the setup code. Try again."
            }
        }
    }

    public nonisolated static let displayDuration: Duration = .seconds(60)
    @Published public private(set) var image: NSImage?
    @Published public private(set) var host: String?
    @Published public private(set) var authenticating = false
    public var available: Bool { settings?.url.scheme?.lowercased() == "https" }
    // Internal for synthetic tests only; the UI has no payload accessor.
    private(set) var payload: Data?
    private var settings: MailboxSettings?
    private var tokenSource: (any TokenSource)?
    private let notificationCenter: NotificationCenter?
    private let copy: @MainActor (String) -> Void
    private let presence: any PresenceCheck
    private let isAppActive: @MainActor () -> Bool
    private let keychain: KeychainQueue
    private let sleep: @Sendable (Duration) async throws -> Void
    private let generation = OSAllocatedUnfairLock(initialState: UUID())
    private var timeout: Task<Void, Never>?
    private enum Phase { case hidden, authenticating, waitingForActivation, reading, visible }
    private var phase = Phase.hidden
    private var activationWaiter: CheckedContinuation<Bool, Never>?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    public init(presence: any PresenceCheck = UserPresence(), keychain: KeychainQueue = .shared,
                notificationCenter: NotificationCenter? = nil,
                isAppActive: (@MainActor () -> Bool)? = nil,
                copy: (@MainActor (String) -> Void)? = nil,
                sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.copy = copy ?? { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.notificationCenter = notificationCenter
        self.presence = presence
        self.isAppActive = isAppActive ?? { NSApp.isActive }
        self.keychain = keychain
        // Keep this async closure in the defining module. A public default
        // closure can emit mismatched async frames in client Debug builds.
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    }

    /// A replacement, even one using the same host with another token file/context, clears setup.
    public func configure(settings: MailboxSettings?, tokenSource: (any TokenSource)? = nil) {
        guard settings != self.settings || tokenSource != nil else { return }
        hide()
        self.settings = settings
        self.tokenSource = tokenSource ?? settings.map { FileTokenSource(path: $0.tokenFile) }
        objectWillChange.send()
    }

    public func show(in window: NSWindow? = nil) async throws {
        hide()
        guard available, let settings, let source = tokenSource else { throw Failure.unavailable }
        let current = generation.withLock { $0 }
        phase = .authenticating
        observe(window: window)
        authenticating = true
        let confirmed = await presence.confirm(reason: "Show the Pond login to pair your phone")
        guard generation.withLock({ $0 == current }) else { throw Failure.cancelled }
        guard !Task.isCancelled else { hide(); throw Failure.cancelled }
        guard confirmed else { hide(); throw Failure.cancelled }
        // LocalAuthentication can finish before its system UI returns activation.
        // Keep no setup material and do not read the token during that handoff.
        phase = .waitingForActivation
        let active = await waitForActivation(current)
        guard active, generation.withLock({ $0 == current }), !Task.isCancelled, isAppActive() else {
            if generation.withLock({ $0 == current }) { hide() }
            throw Failure.cancelled
        }
        phase = .reading
        do {
            let generation = self.generation
            let token = try await keychain.run {
                // A read queued behind another Keychain operation must not start after hiding.
                guard generation.withLock({ $0 == current }) else { throw Failure.cancelled }
                return try source.readToken()
            }
            guard generation.withLock({ $0 == current }), !Task.isCancelled, isAppActive() else { throw Failure.cancelled }
            let pairing = try PhonePairing.make(url: settings.url, token: token, context: settings.context)
            let data = try JSONEncoder().encode(pairing)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let cgImage = CIContext().createCGImage(output, from: output.extent) else { throw Failure.image }
            phase = .visible
            payload = data
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            host = pairing.url.host()
            authenticating = false
            timeout = Task { [weak self, sleep] in
                guard !Task.isCancelled else { return }
                do { try await sleep(Self.displayDuration) } catch { return }
                guard let self, self.generation.withLock({ $0 == current }) else { return }
                self.hide()
            }
        } catch {
            guard generation.withLock({ $0 == current }) else { throw Failure.cancelled }
            hide()
            throw (error as? Failure) ?? Failure.credentials
        }
    }

    /// Called only by the owner's explicit Copy Setup Code action. Never includes an owner key.
    public func copySetupCode() {
        guard image != nil, let payload, let text = String(data: payload, encoding: .utf8) else { return }
        copy(text)
    }

    public func hide() {
        generation.withLock { $0 = UUID() }
        timeout?.cancel()
        timeout = nil
        phase = .hidden
        let waiter = activationWaiter
        activationWaiter = nil
        waiter?.resume(returning: false)
        image = nil
        payload = nil
        host = nil
        authenticating = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func waitForActivation(_ current: UUID) async -> Bool {
        if isAppActive() { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard generation.withLock({ $0 == current }), !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                // MainActor serializes this check/registration with didBecomeActive.
                if isAppActive() { continuation.resume(returning: true) }
                else { activationWaiter = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation.withLock({ $0 == current }) else { return }
                self.hide()
            }
        }
    }

    private func observe(window: NSWindow?) {
        watch(notificationCenter ?? .default, NSApplication.didResignActiveNotification) { controller in
            // System authentication may deactivate Hook. After that handoff,
            // deactivation still clears a pending token read or visible code.
            if controller.phase == .reading || controller.phase == .visible { controller.hide() }
        }
        watch(notificationCenter ?? .default, NSApplication.didBecomeActiveNotification) { controller in
            guard controller.isAppActive(), controller.phase == .waitingForActivation else { return }
            let waiter = controller.activationWaiter
            controller.activationWaiter = nil
            waiter?.resume(returning: true)
        }
        // A system authentication window closing must not cancel the Settings
        // window's attempt. The SwiftUI sheet also clears on explicit dismissal.
        if let window { watch(notificationCenter ?? .default, NSWindow.willCloseNotification, object: window) }
        watch(notificationCenter ?? DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        watch(notificationCenter ?? NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification)
        watch(notificationCenter ?? NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification)
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                       action: @escaping @MainActor (PhonePairingController) -> Void = { $0.hide() }) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}
