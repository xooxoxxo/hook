import Foundation
import RelayCore

/// The crash bar, its crash report window, and the status bar's profile switcher.
extension Store {
#if os(macOS)
    /// The launch check found a crash to offer. A later one replaces it.
    public func offerCrash(_ summary: CrashSummary) {
        let offer = CrashOffer(summary: summary)
        guard crashOffer != offer else { return }
        crashOffer = offer
    }

    /// Not Now: the bar goes, and the crash is handled (`handledKey`) so it isn't raised again.
    public func dismissCrash() {
        guard let offer = crashOffer else { return }
        crashOffer = nil
        crashSheet = nil
        onCrashHandled?(offer.summary.handledKey)
    }

    /// Review…: the crash report window with exactly what a send delivers, to Settings ›
    /// Privacy's target. While it is open for this crash, Review… only brings it forward,
    /// keeping the target picked and a failure shown.
    public func reviewCrash() {
        guard let offer = crashOffer else { return }
        if crashSheet?.summary != offer.summary {
            let targets = crashTargets()
            crashSheet = CrashSheetModel(summary: offer.summary, target: targets.target, pondOffered: targets.pondOffered,
                                         preview: crashReportText(offer.summary))
            HookLog.screen(.crashReport)
            searchIssuesIfNeeded()
        }
        shell.showCrashReport()
    }

    /// GitHub picked and not searched yet: one search for the signature, the only thing that
    /// leaves the Mac before the owner submits in the browser.
    private func searchIssuesIfNeeded() {
        guard let sheet = crashSheet, sheet.target == .github, sheet.match == nil else { return }
        let summary = sheet.summary, search = issueSearch
        Task { [weak self] in
            let match = await search(summary.signature, summary.hookVersion)
            guard let self, self.crashSheet?.summary == summary, self.crashSheet?.match == nil else { return }
            self.crashSheet?.match = match
        }
    }

    /// What a report of this crash says: the allowed fields and the last 40 log lines.
    func crashReportText(_ summary: CrashSummary) -> String {
        let pondVersion: String? = {
            guard sourceKey.hasPrefix("mailbox:"), case .semver(let v)? = pond else { return nil }
            return v.description
        }()
        return CrashReportText.body(summary, source: sourceKey == SourceKey.local ? "This Mac" : "Pond",
                                    pond: pondVersion, log: crashLog())
    }

    /// The segmented control. My Pond only while it is offered.
    public func setCrashTarget(_ target: CrashTarget) {
        guard var sheet = crashSheet, sheet.targets.contains(target), sheet.target != target else { return }
        sheet.target = target
        sheet.send = .idle
        crashSheet = sheet
        searchIssuesIfNeeded()
    }

    /// Cancel, Esc or the window's close button: the window goes, the bar stays.
    public func closeCrashSheet() {
        crashSheet = nil
    }

    /// Copy: exactly the preview.
    public func copyCrashReport() {
        guard let sheet = crashSheet else { return }
        HookLog.action(.copy)
        shell.copy(sheet.preview)
    }

    /// Show in Finder: the .ips the summary was read from.
    public func showCrashReportInFinder() {
        guard let file = crashSheet?.summary.reportFile else { return }
        onShowInFinder?(file.path)
    }

    /// The window's primary button, for its target. A success closes the window; a failure
    /// shows in it.
    public func sendCrashReport() async {
        guard let sheet = crashSheet, !sheet.sending else { return }
        HookLog.action(.sendCrashReport)
        switch sheet.target {
        case .pond: await sendCrashToPond(sheet)
        case .github: sendCrashToGitHub(sheet)
        }
    }

    /// GitHub's outcomes. Nothing is sent here: the browser opens for the owner to submit.
    private func sendCrashToGitHub(_ sheet: CrashSheetModel) {
        switch sheet.match {
        case nil:
            return   // still searching: the button waits
        case .open(_, _, let url)?:
            shell.openURL(url)
            shell.copy(GitHubIssues.comment(sheet.preview))
            closeAndFinish(sheet, message: "Comment copied. Paste it on the issue.")
        case .closedFixed?:
            shell.checkForUpdates()
            closeAndFinish(sheet, message: sheet.matchText ?? "Update Hook.")
        case .none?, .closedOther?, .unavailable?:
            openNewCrashIssue()
        }
    }

    /// A new prefilled issue; when the link had to drop log lines, the full report is copied too.
    public func openNewCrashIssue() {
        guard let sheet = crashSheet, sheet.target == .github else { return }
        let issue = sheet.newIssue
        shell.openURL(issue.url)
        if issue.trimmed { shell.copy(issue.body) }
        closeAndFinish(sheet, message: "Opened a new issue on GitHub. " + (issue.trimmed
            ? "The full report is on the clipboard: paste it over the shortened one."
            : "Review it and submit it there."))
    }

    /// "Check for an Existing Issue": GitHub's issue list for the signature. The window stays.
    public func checkExistingCrashIssue() {
        guard let sheet = crashSheet else { return }
        shell.openURL(GitHubIssues.searchPageURL(signature: sheet.summary.signature))
    }

    private func closeAndFinish(_ sheet: CrashSheetModel, message: String) {
        crashSheet = nil
        finishCrash(sheet.summary, message: message)
    }

    public func sendCrashReport() { Task { await sendCrashReport() } }

    private func sendCrashToPond(_ sheet: CrashSheetModel) async {
        crashSheet?.send = .sending
        do {
            let result = try await postCrash(sheet.summary, body: sheet.preview)
            guard crashSheet?.summary == sheet.summary else { return }
            crashSheet = nil
            finishCrash(sheet.summary, message: result.text)
        } catch {
            guard crashSheet?.summary == sheet.summary else { return }
            if ownerKeyRefused(error) {
                crashSheet = nil
                return
            }
            crashSheet?.send = .failed(UserFacingError.text(error))
        }
    }

    /// Send Automatically to My Pond: no window. A send that fails (or a Pond that isn't
    /// connected yet) leaves the bar instead.
    public func sendCrashAutomatically(_ summary: CrashSummary) async {
        // At launch the Pond may not have answered its version check yet.
        for _ in 0..<Self.pondWaitTries where source == nil || pond == nil {
            try? await sleep(Self.pondWaitStep)
        }
        do {
            let result = try await postCrash(summary, body: crashReportText(summary))
            finishCrash(summary, message: result.text)
        } catch {
            _ = ownerKeyRefused(error)
            offerCrash(summary)
        }
    }

    static let pondWaitTries = 60
    static let pondWaitStep: Duration = .milliseconds(500)

    /// The bug route on Pond 1.2.0 and later; below that the same ask as a plain post.
    private func postCrash(_ summary: CrashSummary, body: String) async throws -> BugPostResult {
        guard let source, sourceKey.hasPrefix("mailbox:") else { throw QueueError.unreachable(Self.noSourceProblem) }
        let instructable = BugAsk.instructable(summary, body: body)
        if pond?.supports(.bugs) == true {
            return try await source.postBug(project: BugAsk.project, instructable: instructable,
                                            signature: summary.signature)
        }
        let posted = try await source.post(project: BugAsk.project, instructable: instructable)
        return posted.deduped ? .occurrence(id: posted.item.id, count: nil) : .filed(id: posted.item.id)
    }

    /// Sent: the bar goes, the crash is handled, and a Notice says what happened.
    func finishCrash(_ summary: CrashSummary, message: String) {
        if crashOffer?.summary.handledKey == summary.handledKey { crashOffer = nil }
        onCrashHandled?(summary.handledKey)
        post(.crashReport(message: message))
    }

#endif

    /// Only on change, so a config reload that keeps the profiles doesn't republish.
    public func setProfiles(_ menu: ProfileMenu) {
        guard profiles != menu else { return }
        profiles = menu
    }

    /// Saves `source` (the shell merges it into config.json, as Settings › Queue does); the
    /// config reload then swaps the queue. Nothing happens for the profile already shown,
    /// or while config.json can't be saved.
    public func switchProfile(_ kind: SourceKind) {
        guard !profiles.readOnly, profiles.current?.kind != kind,
              profiles.profiles.contains(where: { $0.kind == kind }) else { return }
        shell.switchSource(kind)
    }

    public func setUpdating(_ on: Bool) {
        guard updating != on else { return }
        updating = on
    }
}
