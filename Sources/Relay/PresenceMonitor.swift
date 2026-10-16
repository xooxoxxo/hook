import AppKit
import CoreGraphics
import RelayCore

/// Away mode's eyes: watches the screen lock, display sleep, fast user
/// switching and input idle time, decides with `PresenceLogic`, and keeps the
/// away flag file in step. AppDelegate applies the effects through `onChange`.
@MainActor final class PresenceMonitor {
    /// The current decision; `since` is when `state` last changed.
    struct Status: Equatable {
        var state: PresenceState
        var reason: String
        var since: Date
    }

    /// After the state or its reason changed.
    var onChange: (@MainActor (Status) -> Void)?
    private(set) var status = Status(state: .home, reason: "active", since: Date())
    private(set) var mode: PresenceMode = .auto

    private let flag: AwayFlag
    private var awayAfterMinutes = PresenceLogic.defaultAwayAfterMinutes
    private var signals = PresenceSignals()
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var pollTask: Task<Void, Never>?

    init(flag: AwayFlag = .standard) {
        self.flag = flag
    }

    /// Launch: reads the current signals, decides at once and sets or clears the
    /// flag to match, so a flag left by an earlier run never survives.
    func start(mode: PresenceMode, awayAfterMinutes: Int) {
        self.mode = mode
        self.awayAfterMinutes = awayAfterMinutes
        signals = Self.currentSignals()
        let decision = PresenceLogic.evaluate(mode: mode, signals: signals, awayAfterMinutes: awayAfterMinutes)
        status = Status(state: decision.state, reason: decision.reason, since: Date())
        writeFlag()
        NSLog("Relay: presence %@ (%@)", status.state.rawValue, status.reason)
        observe()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refresh()
            }
        }
    }

    /// A config change (Settings or a live reload).
    func configure(mode: PresenceMode, awayAfterMinutes: Int) {
        guard mode != self.mode || awayAfterMinutes != self.awayAfterMinutes else { return }
        self.mode = mode
        self.awayAfterMinutes = awayAfterMinutes
        refresh()
    }

    /// Quit: the flag goes, since nothing would clear it later.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if case .failure(let error) = flag.clear() {
            NSLog("Relay: couldn't remove the away flag: %@", error.localizedDescription)
        }
    }

    // MARK: Signals

    private func observe() {
        let distributed = DistributedNotificationCenter.default()
        watch(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        watch(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false }
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.screensAsleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.screensAsleep = false }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionActive = false }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionActive = true }
    }

    private func watch(_ center: NotificationCenter, _ name: String, _ change: @escaping @MainActor (inout PresenceSignals) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(&self.signals)
                self.refresh()
            }
        }
        observers.append((center, token))
    }

    /// Lock and console state from the window server, for launch, before any
    /// notification has arrived.
    private static func currentSignals() -> PresenceSignals {
        var signals = PresenceSignals(idleSeconds: idleSeconds())
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            signals.screenLocked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
            signals.sessionActive = (session[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        }
        signals.screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        return signals
    }

    private static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Deciding

    /// Re-reads idle time and decides again. Runs every 30 s and on every notification.
    private func refresh() {
        signals.idleSeconds = Self.idleSeconds()
        let decision = PresenceLogic.evaluate(mode: mode, signals: signals, awayAfterMinutes: awayAfterMinutes)
        guard decision.state != status.state || decision.reason != status.reason else { return }
        let old = status.state
        let since = decision.state == old ? status.since : Date()
        status = Status(state: decision.state, reason: decision.reason, since: since)
        writeFlag()
        if decision.state != old {
            NSLog("Relay: presence %@ (%@)", status.state.rawValue, status.reason)
        }
        onChange?(status)
    }

    private func writeFlag() {
        switch status.state {
        case .away:
            if case .failure(let error) = flag.set(reason: status.reason, since: status.since) {
                NSLog("Relay: couldn't write the away flag: %@", error.localizedDescription)
            }
        case .home:
            if case .failure(let error) = flag.clear() {
                NSLog("Relay: couldn't remove the away flag: %@", error.localizedDescription)
            }
        }
    }
}
