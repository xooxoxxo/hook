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
            case .unavailable: "Connect to an HTTPS Pond before pairing an iPhone."
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
    private let keychain: KeychainQueue
    private let sleep: @Sendable (Duration) async throws -> Void
    private let generation = OSAllocatedUnfairLock(initialState: UUID())
    private var timeout: Task<Void, Never>?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    public init(presence: any PresenceCheck = UserPresence(), keychain: KeychainQueue = .shared,
                notificationCenter: NotificationCenter? = nil,
                copy: (@MainActor (String) -> Void)? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.copy = copy ?? { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.notificationCenter = notificationCenter
        self.presence = presence
        self.keychain = keychain
        self.sleep = sleep
    }

    /// A replacement, even one using the same host with another token file/context, clears setup.
    public func configure(settings: MailboxSettings?, tokenSource: (any TokenSource)? = nil) {
        guard settings != self.settings || tokenSource != nil else { return }
        hide()
        self.settings = settings
        self.tokenSource = tokenSource ?? settings.map { FileTokenSource(path: $0.tokenFile) }
        objectWillChange.send()
    }

    public func show() async throws {
        hide()
        guard available, let settings, let source = tokenSource else { throw Failure.unavailable }
        let current = generation.withLock { $0 }
        observe()
        authenticating = true
        let confirmed = await presence.confirm(reason: "Show the Pond login to pair your iPhone")
        guard generation.withLock({ $0 == current }) else { throw Failure.cancelled }
        guard !Task.isCancelled else { hide(); throw Failure.cancelled }
        guard confirmed else { hide(); throw Failure.cancelled }
        do {
            let generation = self.generation
            let token = try await keychain.run {
                // A read queued behind another Keychain operation must not start after hiding.
                guard generation.withLock({ $0 == current }) else { throw Failure.cancelled }
                return try source.readToken()
            }
            guard generation.withLock({ $0 == current }), !Task.isCancelled else { throw Failure.cancelled }
            let pairing = try PhonePairing.make(url: settings.url, token: token, context: settings.context)
            let data = try JSONEncoder().encode(pairing)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let cgImage = CIContext().createCGImage(output, from: output.extent) else { throw Failure.image }
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
        image = nil
        payload = nil
        host = nil
        authenticating = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func observe() {
        watch(notificationCenter ?? .default, NSApplication.didResignActiveNotification)
        watch(notificationCenter ?? .default, NSWindow.willCloseNotification)
        watch(notificationCenter ?? DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        watch(notificationCenter ?? NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification)
        watch(notificationCenter ?? NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification)
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        observers.append((center, token))
    }
}
