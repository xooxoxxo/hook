import AppKit
import CoreGraphics
import Darwin
import IOKit.pwr_mgt
import RelayCore

/// Away mode's eyes: watches the screen lock, display sleep, fast user
/// switching, Screen Sharing sessions and input idle time, decides with
/// `PresenceLogic`, and keeps the away flag file in step. AppDelegate applies
/// the effects through `onChange`.
@MainActor public final class PresenceMonitor {
    /// How often presence is re-checked between lock, sleep and session notifications;
    /// idle time and Screen Sharing are only seen on this poll.
    public static let pollInterval: Duration = .seconds(30)

    /// The current decision; `since` is when `state` last changed.
    public struct Status: Equatable {
        public var state: PresenceState
        public var reason: String
        public var since: Date
    }

    /// After the state or its reason changed.
    public var onChange: (@MainActor (Status) -> Void)?
    public private(set) var status = Status(state: .home, reason: "active", since: Date())
    public private(set) var mode: PresenceMode = .auto

    private let flag: AwayFlag
    private var awayAfterMinutes = PresenceLogic.defaultAwayAfterMinutes
    private var signals = PresenceSignals()
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var pollTask: Task<Void, Never>?
    /// True while reading the power assertions keeps failing, so the failure
    /// is logged once per streak rather than on every poll.
    private var assertionsFailing = false

    public init(flag: AwayFlag = .standard) {
        self.flag = flag
    }

    /// Launch: reads the current signals, decides at once and sets or clears the
    /// flag to match, so a flag left by an earlier run never survives.
    public func start(mode: PresenceMode, awayAfterMinutes: Int) {
        self.mode = mode
        self.awayAfterMinutes = awayAfterMinutes
        signals = Self.currentSignals()
        signals.remoteSession = remoteSessionConnected()
        let decision = PresenceLogic.evaluate(mode: mode, signals: signals, awayAfterMinutes: awayAfterMinutes)
        status = Status(state: decision.state, reason: decision.reason, since: Date())
        writeFlag()
        HookLog.record(.presence(status.state, reason: status.reason))
        observe()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.refresh()
            }
        }
    }

    /// A config change (Settings or a live reload).
    public func configure(mode: PresenceMode, awayAfterMinutes: Int) {
        guard mode != self.mode || awayAfterMinutes != self.awayAfterMinutes else { return }
        self.mode = mode
        self.awayAfterMinutes = awayAfterMinutes
        refresh()
    }

    /// Quit: the flag goes, since nothing would clear it later.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if case .failure(let error) = flag.clear() {
            HookLog.error("AwayFlag", "couldn't remove the away flag: " + error.localizedDescription)
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
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { @Sendable [weak self] _ in
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

    /// Whether a Screen Sharing session is connected, from the processes holding
    /// power assertions. A failed read counts as not connected.
    private func remoteSessionConnected() -> Bool {
        guard let holders = Self.assertionHolders() else {
            if !assertionsFailing {
                assertionsFailing = true
                HookLog.error("Presence", "couldn't read power assertions; treating Screen Sharing as not connected")
            }
            return false
        }
        assertionsFailing = false
        return RemoteSession.isConnected(holders: holders)
    }

    /// The names of the processes holding power assertions, or nil when
    /// `IOPMCopyAssertionsByProcess` fails.
    /// Entries whose value isn't an assertion list are skipped, so one
    /// malformed entry can't hide the others.
    private static func assertionHolders() -> [String]? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [NSNumber: Any]
        else { return nil }
        return byPID.compactMap { pid, value in
            guard let assertions = value as? [[String: Any]] else { return nil }
            if let name = assertions.lazy.compactMap({ $0[processNameKey] as? String }).first, !name.isEmpty {
                return name
            }
            return processName(pid: pid.int32Value)
        }
    }

    /// The process-name key in each assertion dictionary. It is undocumented
    /// (the private kIOPMAssertionProcessNameKey, not in the public IOKit
    /// headers); when it is missing, `processName(pid:)` is the fallback.
    private static let processNameKey = "Process Name"

    private static func processName(pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Deciding

    /// Re-reads idle time and Screen Sharing and decides again. Runs every 30 s
    /// and on every notification.
    private func refresh() {
        signals.idleSeconds = Self.idleSeconds()
        signals.remoteSession = remoteSessionConnected()
        let decision = PresenceLogic.evaluate(mode: mode, signals: signals, awayAfterMinutes: awayAfterMinutes)
        guard decision.state != status.state || decision.reason != status.reason else { return }
        let old = status.state
        let since = decision.state == old ? status.since : Date()
        status = Status(state: decision.state, reason: decision.reason, since: since)
        writeFlag()
        if decision.state != old {
            HookLog.record(.presence(status.state, reason: status.reason))
        }
        onChange?(status)
    }

    private func writeFlag() {
        switch status.state {
        case .away:
            if case .failure(let error) = flag.set(reason: status.reason, since: status.since) {
                HookLog.error("AwayFlag", "couldn't write the away flag: " + error.localizedDescription)
            }
        case .home:
            if case .failure(let error) = flag.clear() {
                HookLog.error("AwayFlag", "couldn't remove the away flag: " + error.localizedDescription)
            }
        }
    }
}
