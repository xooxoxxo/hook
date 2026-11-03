import AppKit
import RelayCore

/// The launch check. It writes this run's marker, and when the last run ended without a clean
/// quit it reads the newest Hook crash report, logs it, and then, by Settings › Privacy:
/// Off records the log line only; Send Automatically to My Pond sends straight away;
/// otherwise the crash is offered (the docked bar). Each signature is raised once.
@MainActor final class CrashMonitor {
    struct Settings: Equatable {
        var crashReports: CrashReportsSetting = .ask
        var target: CrashTarget = .github
        /// A Pond plus an approved owner key.
        var pondOffered = false
    }

    /// How long a launch waits for macOS to finish writing a crash report it hasn't found yet.
    static let reportWait: Duration = .seconds(8)

    private let markerURL: URL
    private let reportsDirectory: URL
    private let defaults: UserDefaults
    private let reporter: any CrashReporter
    /// Read when the check decides, so Settings changes made before then count.
    var settings: () -> Settings = { Settings() }
    /// Show the bar for this crash.
    var onOffer: ((CrashSummary) -> Void)?
    /// Send Automatically to the owner's Pond. Until that path exists the crash is offered.
    var onSendToPond: ((CrashSummary) -> Void)?
    /// The one local notification, when notifications are allowed.
    var onNotify: (() -> Void)?

    private(set) var found: CrashSummary?
    private var check: Task<Void, Never>?

    init(dataDirectory: URL, home: String, defaults: UserDefaults = .standard,
         reporter: any CrashReporter = NoCrashReporter()) {
        markerURL = RunMarkerStore.url(dataDirectory: dataDirectory)
        reportsDirectory = IPSReport.reportsDirectory(home: home)
        self.defaults = defaults
        self.reporter = reporter
    }

    /// Launch: this run's marker, then the check for the last one.
    func start(version: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let previous: RunMarker?
        do {
            previous = try RunMarkerStore.begin(RunMarker(pid: pid, version: version, started: Date()), at: markerURL)
        } catch {
            HookLog.error("RunMarker", "couldn't write the run marker: " + error.localizedDescription)
            return
        }
        CrashReporterControl.apply(settings().crashReports, to: reporter)
        let bundleID = Bundle.main.bundleIdentifier
        guard let ended = RunMarkerStore.uncleanEnd(previous, currentPID: pid, isRunningHook: { other in
            guard let app = NSRunningApplication(processIdentifier: other) else { return false }
            return bundleID != nil && app.bundleIdentifier == bundleID && !app.isTerminated
        }) else { return }
        let reports = reportsDirectory
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let cpu: String = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()
        check = Task { [weak self] in
            // ReportCrash can still be writing the .ips when a relaunch is quick.
            if IPSReport.newest(in: reports, after: ended.started) == nil {
                try? await Task.sleep(for: Self.reportWait)
            }
            let summary = await Task.detached {
                CrashFinder.find(previous: ended, reports: reports, macOS: macOS, cpu: cpu)
            }.value
            self?.handle(summary)
        }
    }

    /// Any clean quit.
    func markClean() {
        do {
            try RunMarkerStore.markClean(at: markerURL)
        } catch {
            HookLog.error("RunMarker", "couldn't mark the run clean: " + error.localizedDescription)
        }
        reporter.stop()
    }

    /// The bar was answered (Not Now, or sent): the signature isn't raised again.
    func markHandled(_ signature: String) {
        var handled = HandledCrashes.load(defaults)
        handled.add(signature)
        handled.save(defaults)
        if found?.signature == signature { found = nil }
    }

    private func handle(_ summary: CrashSummary) {
        HookLog.record(.crashFound(signature: summary.signature, report: summary.report != nil))
        let settings = settings()
        CrashReporterControl.record(summary, setting: settings.crashReports, to: reporter)
        switch CrashDecision.decide(summary, setting: settings.crashReports, target: settings.target,
                                    pondOffered: settings.pondOffered, handled: HandledCrashes.load(defaults)) {
        case .ignore:
            return
        case .sendToPond:
            found = summary
            if let onSendToPond { onSendToPond(summary) } else { offer(summary) }
        case .offer:
            found = summary
            offer(summary)
        }
    }

    private func offer(_ summary: CrashSummary) {
        onOffer?(summary)
        onNotify?()
    }
}
