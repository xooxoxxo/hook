import AppKit
import CoreImage
import Foundation
import RelayCore
import Testing
import os
@testable import RelayMacCore

private struct PairingPresence: PresenceCheck {
    let action: @Sendable () async -> Bool
    func confirm(reason: String) async -> Bool { await action() }
}

@MainActor private final class PairingGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func open(_ answer: Bool) { continuation?.resume(returning: answer); continuation = nil }
}

@MainActor private final class PairingActivity {
    var active: Bool
    var confirmed = false
    var checks = 0
    init(active: Bool = true) { self.active = active }
}

private final class PairingToken: TokenSource, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (reads: 0, onMain: false))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let held: Bool
    init(held: Bool = false) { self.held = held }
    var reads: Int { state.withLock { $0.reads } }
    var onMain: Bool { state.withLock { $0.onMain } }
    func readToken() throws -> String {
        state.withLock { $0.reads += 1; $0.onMain = Thread.isMainThread }
        entered.signal()
        if held { release.wait() }
        return "synthetic-pairing-token"
    }
}

@Suite @MainActor struct MacPhonePairingTests {
    private let settings = MailboxSettings(url: URL(string: "https://pond.example.test")!, tokenFile: "unused", context: "test")
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        throw PhonePairingController.Failure.unavailable
    }
    private func checkCleared(_ controller: PhonePairingController) {
        #expect(controller.image == nil)
        #expect(controller.payload == nil)
        #expect(controller.host == nil)
        #expect(!controller.authenticating)
    }

    @Test(arguments: [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification])
    func systemAuthenticationHandoffDoesNotCancelAnAuthenticatedAttempt(_ event: Notification.Name) async throws {
        let gate = PairingGate(), token = PairingToken(), notifications = NotificationCenter()
        let controller = PhonePairingController(presence: PairingPresence { await gate.wait() }, notificationCenter: notifications, isAppActive: { true })
        controller.configure(settings: settings, tokenSource: token)
        defer { controller.hide() }
        let task = Task { try await controller.show() }
        try await waitFor { gate.waiting }
        notifications.post(name: event, object: NSObject())
        #expect(controller.image == nil && token.reads == 0)
        gate.open(true)
        try await task.value
        #expect(controller.image != nil && token.reads == 1)
    }

    @Test func authenticationWaitsForHookToBecomeActiveBeforeReadingTheToken() async throws {
        let gate = PairingGate(), token = PairingToken(), notifications = NotificationCenter()
        let activity = PairingActivity()
        let controller = PhonePairingController(presence: PairingPresence {
            let answer = await gate.wait()
            await MainActor.run { activity.confirmed = true }
            return answer
        }, notificationCenter: notifications, isAppActive: { activity.active })
        controller.configure(settings: settings, tokenSource: token)
        defer { controller.hide() }
        let task = Task { try await controller.show() }
        try await waitFor { gate.waiting }
        activity.active = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        gate.open(true)
        try await waitFor { activity.confirmed }
        #expect(token.reads == 0 && controller.payload == nil && controller.authenticating)
        // An unrelated/spurious notification cannot authorize a token read.
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(token.reads == 0 && controller.payload == nil)
        activity.active = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await task.value
        #expect(token.reads == 1 && controller.image != nil)
    }

    @Test func losingActivationBeforeTheHandoffResumesDoesNotReadTheToken() async throws {
        let token = PairingToken(), notifications = NotificationCenter()
        let activity = PairingActivity(active: false)
        let controller = PhonePairingController(presence: PairingPresence { true },
            notificationCenter: notifications, isAppActive: { activity.checks += 1; return activity.active })
        controller.configure(settings: settings, tokenSource: token)
        let task = Task { try await controller.show() }
        // The second activity read is in the waiter's MainActor registration.
        try await waitFor { activity.checks >= 2 }
        activity.active = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        activity.active = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        await #expect(throws: PhonePairingController.Failure.cancelled) { try await task.value }
        checkCleared(controller)
        #expect(token.reads == 0)
    }

    @Test(arguments: ["close", "lock", "session", "sleep", "source", "hide", "cancel"])
    func criticalPrivacyEventsCancelTheAuthenticationHandoff(_ event: String) async throws {
        let gate = PairingGate(), token = PairingToken(), notifications = NotificationCenter()
        let activity = PairingActivity()
        let controller = PhonePairingController(presence: PairingPresence {
            let answer = await gate.wait()
            await MainActor.run { activity.confirmed = true }
            return answer
        }, notificationCenter: notifications, isAppActive: { false })
        controller.configure(settings: settings, tokenSource: token)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let task = Task { try await controller.show(in: window) }
        try await waitFor { gate.waiting }
        gate.open(true)
        try await waitFor { activity.confirmed }
        switch event {
        case "close": notifications.post(name: NSWindow.willCloseNotification, object: window)
        case "lock": notifications.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        case "session": notifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        case "sleep": notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        case "source": controller.configure(settings: nil)
        case "hide": controller.hide()
        default: task.cancel()
        }
        await #expect(throws: PhonePairingController.Failure.cancelled) { try await task.value }
        checkCleared(controller)
        #expect(token.reads == 0)
    }

    @Test func unrelatedWindowsDoNotDismissTheCodeButDeactivationDuringAReadStillCancels() async throws {
        let notifications = NotificationCenter()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let controller = PhonePairingController(presence: PairingPresence { true }, notificationCenter: notifications, isAppActive: { true })
        controller.configure(settings: settings, tokenSource: PairingToken())
        try await controller.show(in: window)
        notifications.post(name: NSWindow.willCloseNotification, object: other)
        #expect(controller.image != nil)
        controller.hide()
        let token = PairingToken(held: true)
        controller.configure(settings: settings, tokenSource: token)
        let task = Task { try await controller.show(in: window) }
        try await waitFor { token.reads == 1 }
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        token.release.signal()
        await #expect(throws: PhonePairingController.Failure.cancelled) { try await task.value }
        checkCleared(controller)
    }

    @Test func noQRBeforeAuthenticationAndCancellationNeverReadsTheToken() async throws {
        let gate = PairingGate(), token = PairingToken()
        let controller = PhonePairingController(presence: PairingPresence { await gate.wait() }, notificationCenter: NotificationCenter(), isAppActive: { true })
        controller.configure(settings: settings, tokenSource: token)
        let task = Task { try await controller.show() }
        try await waitFor { gate.waiting }
        #expect(controller.image == nil && controller.payload == nil)
        #expect(token.reads == 0)
        gate.open(false)
        await #expect(throws: PhonePairingController.Failure.cancelled) { try await task.value }
        checkCleared(controller)
        #expect(token.reads == 0)
    }

    @Test func successfulAuthenticationCreatesAValidatedCodeOnlyInMemory() async throws {
        let token = PairingToken()
        let controller = PhonePairingController(presence: PairingPresence { true }, notificationCenter: NotificationCenter(), isAppActive: { true })
        controller.configure(settings: settings, tokenSource: token)
        defer { controller.hide() }
        try await controller.show()
        #expect(token.reads == 1 && !token.onMain)
        let bytes = try #require(controller.payload)
        let pairing = try PhonePairing.decode(bytes)
        #expect(pairing.token == "synthetic-pairing-token")
        #expect(pairing.url == settings.url && pairing.context == "test")
        #expect(controller.host == "pond.example.test")
        let image = try #require(controller.image)
        for _ in 0..<2 {
            let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                 options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let feature = try #require(detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)
            let message = try #require(feature.messageString)
            #expect(try PhonePairing.decode(Data(message.utf8)) == pairing)
        }
    }

    @Test func lateAuthenticationCannotReadAfterHideOrTaskCancellation() async throws {
        for cancelTask in [false, true] {
            let gate = PairingGate(), token = PairingToken()
            let controller = PhonePairingController(presence: PairingPresence { await gate.wait() }, notificationCenter: NotificationCenter(), isAppActive: { true })
            controller.configure(settings: settings, tokenSource: token)
            let task = Task { try await controller.show() }
            try await waitFor { gate.waiting }
            if cancelTask { task.cancel() } else { controller.hide() }
            gate.open(true)
            await #expect(throws: PhonePairingController.Failure.cancelled) { try await task.value }
            checkCleared(controller)
            #expect(token.reads == 0)
        }
    }

    @Test func aTokenReadAlreadyInFlightCannotRepublishAfterHide() async throws {
        let token = PairingToken(held: true)
        let controller = PhonePairingController(presence: PairingPresence { true }, keychain: KeychainQueue(label: "test.pairing.held"), notificationCenter: NotificationCenter(), isAppActive: { true })
        controller.configure(settings: settings, tokenSource: token)
        let task = Task { try await controller.show() }
        try await waitFor { token.reads == 1 }
        controller.hide()
        token.release.signal()
        await #expect(throws: PhonePairingController.Failure.cancelled) { try await task.value }
        checkCleared(controller)
    }

    @Test func hidingCancelsAnAlreadySleepingDisplayTimer() async throws {
        let state = OSAllocatedUnfairLock(initialState: (started: false, cancelled: false))
        let controller = PhonePairingController(presence: PairingPresence { true },
            notificationCenter: NotificationCenter(), isAppActive: { true }, sleep: { duration in
                state.withLock { $0.started = true }
                do { try await Task.sleep(for: duration) }
                catch { state.withLock { $0.cancelled = true }; throw error }
            })
        controller.configure(settings: settings, tokenSource: PairingToken())
        try await controller.show()
        try await waitFor { state.withLock { $0.started } }
        controller.hide()
        try await waitFor { state.withLock { $0.cancelled } }
        checkCleared(controller)
    }

    @Test func timeoutHidesMaterialAtSixtySecondsWithoutChangingTheCredential() async throws {
        let gate = PairingGate()
        let controller = PhonePairingController(presence: PairingPresence { true }, notificationCenter: NotificationCenter(), isAppActive: { true }, sleep: { duration in
            #expect(duration == .seconds(60))
            _ = await gate.wait()
        })
        let token = PairingToken()
        controller.configure(settings: settings, tokenSource: token)
        try await controller.show()
        try await waitFor { gate.waiting }
        #expect(controller.image != nil)
        gate.open(true)
        try await waitFor { controller.image == nil }
        checkCleared(controller)
        #expect(token.reads == 1)
    }

    @Test func closingDeactivatingLockingAndSourceReplacementClearMaterial() async throws {
        for event in ["close", "deactivate", "lock", "source"] {
            let notifications = NotificationCenter()
            let controller = PhonePairingController(presence: PairingPresence { true }, notificationCenter: notifications, isAppActive: { true })
            controller.configure(settings: settings, tokenSource: PairingToken())
            _ = NSApplication.shared
            let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            try await controller.show(in: window)
            switch event {
            case "close": notifications.post(name: NSWindow.willCloseNotification, object: window)
            case "deactivate": notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
            case "lock": notifications.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
            default: controller.configure(settings: nil)
            }
            try await waitFor { controller.image == nil }
            checkCleared(controller)
        }
    }

    @Test func pasteFallbackCopiesOnlyAfterAnExplicitActionAndNeverAnOwnerKey() async throws {
        var copies: [String] = []
        let controller = PhonePairingController(presence: PairingPresence { true },
            notificationCenter: NotificationCenter(), isAppActive: { true }, copy: { copies.append($0) })
        controller.configure(settings: settings, tokenSource: PairingToken())
        controller.copySetupCode()
        #expect(copies.isEmpty)
        try await controller.show()
        #expect(copies.isEmpty)
        controller.copySetupCode()
        #expect(copies.count == 1)
        let bytes = try #require(copies.first?.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["v", "url", "token", "context"])
        #expect(try PhonePairing.decode(bytes).token == "synthetic-pairing-token")
        controller.hide()
        controller.copySetupCode()
        #expect(copies.count == 1)
    }

    @Test func insecureSourceNeverPromptsOrReads() async throws {
        let token = PairingToken()
        let controller = PhonePairingController(presence: PairingPresence { Issue.record("Should not authenticate"); return true }, notificationCenter: NotificationCenter(), isAppActive: { true })
        controller.configure(settings: MailboxSettings(url: URL(string: "http://pond.example.test")!, tokenFile: "unused", context: "test"), tokenSource: token)
        await #expect(throws: PhonePairingController.Failure.unavailable) { try await controller.show() }
        #expect(token.reads == 0)
        checkCleared(controller)
    }
}
