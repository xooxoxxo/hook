import Foundation

/// Settings › Privacy › Crash reports.
public enum CrashReportsSetting: String, Codable, Sendable, CaseIterable {
    /// Ask Each Time (the default): the bar, then the sheet.
    case ask
    /// Send Automatically: straight to the owner's Pond; GitHub still needs a review.
    case auto
    /// Off: no bar, no send; only the log line.
    case off
}

/// Settings › Privacy › Send to.
public enum CrashTarget: String, Codable, Sendable, CaseIterable {
    case github
    case pond

    /// A saved `pond` without a Pond and an approved owner key reads as GitHub.
    public func effective(pondOffered: Bool) -> CrashTarget {
        self == .pond && pondOffered ? .pond : .github
    }
}

/// The crashes already raised (`CrashSummary.handledKey`), so each is raised once.
/// UserDefaults `relay.crash.handled`, the last 50.
public struct HandledCrashes: Equatable, Sendable {
    public static let defaultsKey = "relay.crash.handled"
    public static let limit = 50

    public private(set) var signatures: [String]

    public init(signatures: [String] = []) {
        self.signatures = Array(signatures.suffix(Self.limit))
    }

    public func contains(_ signature: String) -> Bool { signatures.contains(signature) }

    public mutating func add(_ signature: String) {
        signatures.removeAll { $0 == signature }
        signatures.append(signature)
        if signatures.count > Self.limit { signatures.removeFirst(signatures.count - Self.limit) }
    }

    public static func load(_ defaults: UserDefaults) -> HandledCrashes {
        HandledCrashes(signatures: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public func save(_ defaults: UserDefaults) {
        defaults.set(signatures, forKey: Self.defaultsKey)
    }
}

/// What the launch check does with a crash it found.
public enum CrashDecision: Equatable, Sendable {
    /// Off, or already raised: the log line only.
    case ignore
    /// The docked bar (and the sheet on Review…).
    case offer
    /// Send Automatically to the owner's own Pond.
    case sendToPond

    public static func decide(_ summary: CrashSummary, setting: CrashReportsSetting, target: CrashTarget,
                              pondOffered: Bool, handled: HandledCrashes) -> CrashDecision {
        guard setting != .off, !handled.contains(summary.handledKey) else { return .ignore }
        if setting == .auto, target.effective(pondOffered: pondOffered) == .pond { return .sendToPond }
        return .offer
    }
}

/// A crash the panel offers to report: the docked bar above the status bar, until it is
/// answered (Not Now, or sent).
public struct CrashOffer: Equatable, Sendable {
    public var summary: CrashSummary

    public init(summary: CrashSummary) {
        self.summary = summary
    }
}

/// Option B: the slot for a crash-reporting SDK (Sentry or TelemetryDeck, not chosen yet).
/// Any adapter lives in the `HookTelemetry` target, and only ever starts with consent.
public protocol CrashReporter: Sendable {
    func start(consent: Bool)
    func record(_ summary: CrashSummary)
    func stop()
}

/// The only reporter in 0.12: it does nothing.
public struct NoCrashReporter: CrashReporter {
    public init() {}
    public func start(consent: Bool) {}
    public func record(_ summary: CrashSummary) {}
    public func stop() {}
}

/// Drives a `CrashReporter` from the setting, so nothing starts or records when it is Off.
public enum CrashReporterControl {
    public static func apply(_ setting: CrashReportsSetting, to reporter: any CrashReporter) {
        if setting == .off { reporter.stop() } else { reporter.start(consent: true) }
    }

    public static func record(_ summary: CrashSummary, setting: CrashReportsSetting, to reporter: any CrashReporter) {
        guard setting != .off else { return }
        reporter.record(summary)
    }
}
