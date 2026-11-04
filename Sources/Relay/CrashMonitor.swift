import AppKit
import RelayCore

/// The launch check. It writes this run's marker and launch record, then looks at how the
/// last run ended (`StartPlan`):
/// - quit for a cause nobody expected (a signal, another app, code): offered as "Hook was
///   closed: <cause>";
/// - ended without quitting: the newest Hook crash report is read and offered;
/// - force-quit by the installer or updater after they asked: logged only.
/// By Settings › Privacy, Off records the log line only and Send Automatically to My Pond sends
/// straight away; otherwise the bar is offered. Each crash is raised once.
///
/// Two guards keep a fatal offer from looping (macOS 27, 0.12.0: each start offered the last
/// crash and died while offering it). The crash is marked handled and written to
/// `crash-offer.json` before anything shows; a run that dies within 20 s of its offer makes
/// the next start back off with one quiet Notice. And when the last 3 runs each died within
/// 15 s of starting, this start is in safe mode: no offer, no update check, no agents sync.
@MainActor final class CrashMonitor {
    struct Settings: Equatable {
        var crashReports: CrashReportsSetting = .ask
        var target: CrashTarget = .github
        /// A Pond plus an approved owner key.
        var pondOffered = false
    }

    /// How long a launch waits for macOS to finish writing a crash report it hasn't found yet.
    static let reportWait: Duration = .seconds(8)

    private let dataDirectory: URL
    private let markerURL: URL
    private let launchesURL: URL
    private let offerURL: URL
    private let reportsDirectory: URL
    private let defaults: UserDefaults
    private let reporter: any CrashReporter
    private let pid = ProcessInfo.processInfo.processIdentifier
    /// Read when the check decides, so Settings changes made before then count.
    var settings: () -> Settings = { Settings() }
    /// Show the bar for this crash.
    var onOffer: ((CrashSummary) -> Void)?
    /// Send Automatically to the owner's Pond. Until that path exists the crash is offered.
    var onSendToPond: ((CrashSummary) -> Void)?
    /// The one local notification, when notifications are allowed.
    var onNotify: (() -> Void)?
    /// A quiet Notice in the panel (the back-off and safe mode).
    var onNotice: ((String) -> Void)?

    private(set) var found: CrashSummary?
    /// The last 3 runs died early: the optional launch work is skipped.
    private(set) var safeMode = false
    private var check: Task<Void, Never>?
    private var timers: [Task<Void, Never>] = []

    init(dataDirectory: URL, home: String, defaults: UserDefaults = .standard,
         reporter: any CrashReporter = NoCrashReporter()) {
        self.dataDirectory = dataDirectory
        markerURL = RunMarkerStore.url(dataDirectory: dataDirectory)
        launchesURL = LaunchHistory.url(dataDirectory: dataDirectory)
        offerURL = CrashOfferGuard.url(dataDirectory: dataDirectory)
        reportsDirectory = IPSReport.reportsDirectory(home: home)
        self.defaults = defaults
        self.reporter = reporter
    }

    /// Launch: this run's marker and launch record, then the check for the last run.
    func start(version: String) {
        let now = Date()
        let previous: RunMarker?
        do {
            previous = try RunMarkerStore.begin(RunMarker(pid: pid, version: version, started: now), at: markerURL)
        } catch {
            HookLog.error("RunMarker", "couldn't write the run marker: " + error.localizedDescription)
            return
        }
        let history = (try? LaunchHistory.begin(LaunchRecord(pid: pid, started: now), at: launchesURL)) ?? []
        let request = QuitRequest.take(dataDirectory: dataDirectory)
        let bundleID = Bundle.main.bundleIdentifier
        let plan = StartPlan.make(previous: previous, history: history, offer: CrashOfferGuard.read(offerURL),
                                  request: request, currentPID: pid, isRunningHook: { other in
            guard let app = NSRunningApplication(processIdentifier: other) else { return false }
            return bundleID != nil && app.bundleIdentifier == bundleID && !app.isTerminated
        })
        let launches = launchesURL, me = pid
        after(seconds: LaunchHistory.window) { try? LaunchHistory.markSurvived(pid: me, at: launches) }
        CrashReporterControl.apply(settings().crashReports, to: reporter)
        if case .forceQuit(_, let cause) = plan.lastRun { HookLog.record(.lastRun(clean: false, cause: cause)) }
        if let record = plan.backOff { backOff(record) }
        if plan.safeMode {
            safeMode = true
            HookLog.error("SafeMode", "the last \(LaunchHistory.strikes) runs ended within "
                + "\(Int(LaunchHistory.window)) s of starting; skipping the crash offer, the update check and the agents sync")
            onNotice?(LaunchHistory.safeModeNotice)
        }
        guard plan.offers else { return }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let cpu: String = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()
        switch plan.lastRun {
        case .fine, .forceQuit:
            return
        case .closed(let marker, let cause):
            handle(CrashSummary(report: nil, hookVersion: marker.version, macOS: macOS, cpu: cpu,
                                when: marker.ended ?? marker.started, closed: cause, run: marker.started))
        case .crashed(let ended):
            let reports = reportsDirectory
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
    }

    /// The last run died while offering `record`: handled now, logged, one quiet Notice.
    private func backOff(_ record: CrashOfferRecord) {
        markHandled(record.key)
        HookLog.error("CrashOffer", "the last run ended within \(Int(CrashOfferGuard.survival)) s of offering crash "
            + record.signature + "; not offered again")
        guard !record.noticeShown else { return }
        var shown = record
        shown.noticeShown = true
        try? CrashOfferGuard.write(shown, to: offerURL)
        onNotice?(CrashOfferGuard.backOffNotice)
    }

    /// Any quit that goes through AppKit, with its cause.
    func markClean(cause: QuitCause) {
        do {
            try RunMarkerStore.markClean(at: markerURL, pid: pid, cause: cause, ended: Date())
        } catch {
            HookLog.error("RunMarker", "couldn't mark the run clean: " + error.localizedDescription)
        }
        try? LaunchHistory.markClean(pid: pid, at: launchesURL)
        reporter.stop()
    }

    /// The bar was answered (Not Now, or sent), or offered: it isn't raised again.
    func markHandled(_ key: String) {
        var handled = HandledCrashes.load(defaults)
        handled.add(key)
        handled.save(defaults)
        if found?.handledKey == key { found = nil }
    }

    private func handle(_ summary: CrashSummary) {
        HookLog.record(.crashFound(signature: summary.signature, report: summary.report != nil,
                                   closed: summary.closed?.kind))
        let settings = settings()
        CrashReporterControl.record(summary, setting: settings.crashReports, to: reporter)
        switch CrashDecision.decide(summary, setting: settings.crashReports, target: settings.target,
                                    pondOffered: settings.pondOffered, handled: HandledCrashes.load(defaults)) {
        case .ignore:
            return
        case .sendToPond:
            guard record(summary) else { return }
            found = summary
            if let onSendToPond { onSendToPond(summary) } else { offer(summary) }
        case .offer:
            guard record(summary) else { return }
            found = summary
            offer(summary)
        }
    }

    /// Before anything shows: the crash is handled, so a death while offering it can't offer
    /// it again, and the offer is on disk (fsync'd), so the next start can tell it was fatal.
    /// Nothing is offered when the record can't be written.
    private func record(_ summary: CrashSummary) -> Bool {
        var handled = HandledCrashes.load(defaults)
        handled.add(summary.handledKey)
        handled.save(defaults)
        let url = offerURL, key = summary.handledKey
        do {
            try CrashOfferGuard.write(CrashOfferRecord(key: key, signature: summary.signature, pid: pid, at: Date()),
                                      to: url)
        } catch {
            HookLog.error("CrashOffer", "couldn't record the offer, so it isn't made: " + error.localizedDescription)
            return false
        }
        after(seconds: CrashOfferGuard.survival) {
            guard var record = CrashOfferGuard.read(url), record.key == key else { return }
            record.survived = true
            try? CrashOfferGuard.write(record, to: url)
        }
        return true
    }

    private func offer(_ summary: CrashSummary) {
        onOffer?(summary)
        onNotify?()
    }

    private func after(seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        timers.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            work()
        })
    }
}
