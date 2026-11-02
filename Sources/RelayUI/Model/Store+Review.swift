import CryptoKit
import Foundation
import RelayCore

/// Where the Store keeps its sealed review records: the Keychain that holds the seal key, and
/// `reviews.json` (mode 0600, in Hook's data directory).
public struct ReviewPersistence: Sendable {
    public var secrets: any SecretStore
    public var url: URL

    public init(secrets: any SecretStore, url: URL) {
        self.secrets = secrets
        self.url = url
    }
}

/// Corrections: every revised ask is checked and rendered from the revision the review gate
/// names, at ingestion, so no list, card or detail path reads an unreviewed body.
extension Store {
    // MARK: Ingestion

    /// A list (or closed-list) item: its current revision verified, merged into the fetched
    /// history, pinned, and rendered.
    func ingestListed(_ raw: WireItem) -> WireItem {
        // An item served exactly as before was verified then; a poll re-checks only what changed.
        if served[raw.id] != raw || listedHistories[raw.id] == nil {
            listedHistories[raw.id] = RevisionCheck.verify(listed: raw)
        }
        served[raw.id] = raw
        settleHistory(raw.id)
        return render(raw)
    }

    /// A fetched detail: its whole history verified and pinned. The stored copy has the rendered
    /// item and no revisions; the bodies live only in `histories`.
    func ingestDetail(_ raw: AskDetail) -> AskDetail {
        let id = raw.item.id
        served[id] = raw.item
        fetchedHistories[id] = RevisionCheck.verify(raw)
        listedHistories[id] = RevisionCheck.verify(listed: raw.item)
        settleHistory(id)
        return AskDetail(item: render(raw.item), events: raw.events, revisions: [])
    }

    private func settleHistory(_ id: String) {
        histories[id] = RevisionCheck.merge(fetched: fetchedHistories[id], listed: listedHistories[id])
        pin(id)
        holdBackStaleDone(id)
    }

    /// A Done held for Undo was bound to the revision then shown; a new current revision
    /// drops it, so it can't land on a version the owner never saw.
    private func holdBackStaleDone(_ id: String) {
        guard let close = pending.entry(id), close.verdict == .done, case .success(let history)? = histories[id] else { return }
        let stale = close.stamp.map { $0 != history.current } ?? (history.current.rev > 1)
        guard stale else { return }
        _ = pending.undo(id)
        updateItems()
        post(.doneHeldBack(id: id, title: close.title))
    }

    // MARK: The copy and open guard

    /// Copies only while the ask is legacy (and `stamp` is nil) or current at exactly `stamp`,
    /// and `text` is a command the rendered revision shows. Runs on the main actor, the one that
    /// applies polls, so no correction can land between the check and the copy.
    @discardableResult public func copyCode(_ id: String, stamp: RevisionStamp?, text: String) -> CopyOutcome {
        guard actsOnShown(id, stamp: stamp),
              (nodes(for: id).map(Flow.flattened) ?? []).contains(where: { $0.code.map(Sanitize.copyText) == text })
        else { return .refused }
        shell.copy(text)
        return .copied
    }

    /// Opens only under `copyCode`'s rule, and only a web URL the rendered revision shows.
    public func openStepURL(_ id: String, stamp: RevisionStamp?, url: URL) {
        guard actsOnShown(id, stamp: stamp), shows(id, url: url) else { return }
        shell.openURL(url)
    }

    /// Copy Link Address: copies only under `copyCode`'s rule, and only a web URL the rendered revision shows.
    @discardableResult public func copyLinkAddress(_ id: String, stamp: RevisionStamp?, url: URL) -> CopyOutcome {
        guard actsOnShown(id, stamp: stamp), shows(id, url: url) else { return .refused }
        shell.copy(url.absoluteString)
        return .copied
    }

    /// A file row's Open, Open With, Reveal in Finder or Copy Path: only under `copyCode`'s
    /// rule, and only for a file (`path` as sent) a step or a link of the rendered revision names.
    public func allowsFileAction(_ id: String, stamp: RevisionStamp?, path: String) -> Bool {
        guard actsOnShown(id, stamp: stamp) else { return false }
        let steps = (nodes(for: id).map(Flow.flattened) ?? []).compactMap(\.file)
        let links = (item(for: id)?.instructable?.links ?? []).compactMap(\.file)
        return (steps + links).contains(path)
    }

    /// A web URL a step, a link, or a link in a step's detail of the rendered revision names.
    private func shows(_ id: String, url: URL) -> Bool {
        guard LinkDisplay.isWeb(url.absoluteString) else { return false }
        let nodes = nodes(for: id).map(Flow.flattened) ?? []
        let steps = nodes.compactMap(\.url)
        let links = (item(for: id)?.instructable?.links ?? []).compactMap(\.url)
        if (steps + links).contains(where: { URL(string: $0) == url }) { return true }
        return nodes.compactMap(\.detail).contains { DetailText.webLinks($0).contains(url.absoluteString) }
    }

    /// The ask is unlocked and `stamp` is the revision it renders now.
    func actsOnShown(_ id: String, stamp: RevisionStamp?) -> Bool {
        switch reviewState(id) {
        case .legacy: return stamp == nil
        case .current(let current): return stamp == current && renderedStamp(id) == current
        case .pending, .historyChanged: return false
        }
    }

    static let ownerKeySetUpReason = "Set up the owner key in Settings › Queue to act on corrected asks."

    /// A failed act's reason; a correction that raced the act reads "the ask was corrected", and
    /// a Pond that wants the owner key says where to set it up.
    static func failureReason(_ error: any Error) -> String {
        switch error as? QueueError {
        case .corrected?: return "the ask was corrected"
        case .rejected(403, "owner key required", _)?: return ownerKeySetUpReason
        default: return UserFacingError.text(error)
        }
    }

    /// A failure `failureReason` words itself rather than the answers' own text.
    static func isReviewFailure(_ error: any Error) -> Bool {
        switch error as? QueueError {
        case .corrected?, .rejected(403, "owner key required", _)?: return true
        default: return false
        }
    }

    // MARK: Accept

    /// Use Version N: accepts exactly `stamp`, the verified current revision. A change to a
    /// command, link or file (since the baseline, or since rev 1 on a first view) asks for Touch
    /// ID first. The acceptance is local and sealed before the Pond hears of it: the Pond is
    /// not trusted for it, so a failed Pond call keeps it and marks the record to resend.
    @discardableResult public func acceptRevision(_ id: String, stamp: RevisionStamp) async -> Bool {
        if reviewsUnreadable { retryReviewKey() }
        guard !reviewsUnreadable else {
            post(.reviewRecordsUnreadable)
            return false
        }
        guard case .pending(_, let current, _) = reviewState(id), current == stamp,
              let diff = reviewDiff(id), let before = item(for: id)?.instructable else { return false }
        if diff.touchesCommandsLinksOrFiles {
            let title = Sanitize.revealLine(item(for: id)?.title ?? "")
            guard await shell.confirmPresence("accept a changed command, link or file in “\(title)”") else { return false }
            // A poll may have landed during the prompt: accept only what was on screen.
            guard case .pending(_, let still, _) = reviewState(id), still == stamp else { return false }
        }
        var next = record(id) ?? ReviewRecord()
        next.accepted = stamp
        next.seen = stamp
        next.changed = diff.changedIDs + diff.addedIDs
        next.added = diff.addedIDs
        next.pondAcceptPending = true
        setRecord(next, for: id)
        saveReviewsNow()
        resetAfterAccept(id, before: before, diff: diff)
        rerender(id)
        queueInputChanged()
        objectWillChange.send()

        guard let source else { return true }
        let gen = generation
        do {
            _ = try await source.accept(id, stamp: stamp)
            guard gen == generation else { return true }
            markAcceptSent(id)
        } catch {
            guard gen == generation else { return true }
            if !ownerKeyRefused(error) {
                post(.acceptFailed(id: id, title: item(for: id)?.title ?? "", reason: Self.failureReason(error)))
            }
        }
        return true
    }

    /// Expanded rows, the scroll anchor, answers being changed, and drafts for changed or
    /// removed questions go; a moved question's draft follows its step.
    private func resetAfterAccept(_ id: String, before: Instructable, diff: RevisionDiff) {
        expandedDone[id] = nil
        expandedTodo[id] = nil
        editingAnswers[id] = nil
        let dropped = Set(diff.steps.filter { $0.kind == .changed || $0.kind == .removed }.map(\.stepID))
        let oldIDs = Dictionary(StepIdentity.paths(before).map { ($1, $0) }) { first, _ in first }
        let newPaths = (try? histories[id]?.get()).flatMap { $0.currentBody }.map(StepIdentity.paths) ?? [:]
        if let drafts = answerDrafts[id] {
            var kept: [String: AnswerDraft] = [:]
            for (path, draft) in drafts {
                guard let stepID = oldIDs[path], !dropped.contains(stepID), let moved = newPaths[stepID] else { continue }
                kept[moved] = draft
            }
            answerDrafts[id] = kept.isEmpty ? nil : kept
        }
        if let first = diff.steps.first(where: { $0.kind == .changed || $0.kind == .added })?.newPath {
            detailAnchor[id] = first
        } else {
            detailAnchor[id] = nil
        }
    }

    /// The Pond took the acceptance: nothing to resend.
    func markAcceptSent(_ id: String) {
        guard var next = record(id), next.pondAcceptPending else { return }
        next.pondAcceptPending = false
        setRecord(next, for: id)
        saveReviewsNow()
    }

    /// Before Done or answers: an acceptance the Pond hasn't taken yet is sent first. Throws
    /// what the Pond answered, and then the act isn't sent.
    func sendPendingAccept(_ id: String, via source: any QueueSource) async throws {
        guard let record = record(id), record.pondAcceptPending, let accepted = record.accepted else { return }
        _ = try await source.accept(id, stamp: accepted)
        markAcceptSent(id)
    }

    /// A 409 whose in-force rev is below what this Mac accepted, for exactly the stamp it
    /// accepted, means the Pond missed the acceptance: send it once and retry the act once.
    /// Any other 409 is thrown as it is.
    func withAcceptRecovery(_ id: String, via source: any QueueSource, _ act: () async throws -> Void) async throws {
        do {
            try await act()
        } catch QueueError.corrected(let rev, let hash, let acceptedRev) {
            guard let accepted = record(id)?.accepted, accepted == RevisionStamp(rev: rev, hash: hash),
                  (acceptedRev ?? 0) < accepted.rev else {
                throw QueueError.corrected(rev: rev, hash: hash, acceptedRev: acceptedRev)
            }
            _ = try await source.accept(id, stamp: accepted)
            markAcceptSent(id)
            try await act()
        }
    }

    /// The seal key again, after a refused read: the owner may allow Hook this time.
    func retryReviewKey() {
        guard reviewsUnreadable else { return }
        reviewsUnreadable = false
        pendingReviewNotice = nil
        loadReviews()
        pendingReviewNotice = nil
    }

    /// The item with its payload replaced by the body the gate names, else the last body
    /// rendered from a verified revision, else a stand-in with the title and no steps. Works on
    /// a raw or an already rendered item, so `rerender` can run it again.
    func render(_ item: WireItem) -> WireItem {
        let state = reviewState(item.id)
        if case .legacy = state { return item }
        var out = item
        out.revision = nil
        let history = try? histories[item.id]?.get()
        if let body = ReviewGate.renderedBody(state, history: history) {
            lastRendered[item.id] = body
            out.payload = Payload(instructable: body)
        } else if let last = lastRendered[item.id] {
            out.payload = Payload(instructable: last)
        } else {
            // Title, urgency and origin never change across revisions; nothing else is shown.
            let current = history?.currentBody
            out.payload = Payload(instructable: Instructable(
                v: 1, title: current?.title ?? item.title, urgency: current?.urgency ?? item.payload.instructable?.urgency,
                steps: [], from: current?.from))
        }
        return out
    }

    /// Renders the ask again everywhere it is stored, after its history or review record changed.
    func rerender(_ id: String) {
        holdingQueue {
            if let index = listed.firstIndex(where: { $0.id == id }) {
                let item = render(listed[index])
                if item != listed[index] {
                    listed[index] = item
                    updateItems()
                }
            }
            if var detail = details[id] {
                let item = render(detail.item)
                if item != detail.item {
                    detail.item = item
                    details[id] = detail
                    tickCache[id] = nil
                }
            }
            if let index = recentlyClosed.firstIndex(where: { $0.id == id }) {
                let item = render(recentlyClosed[index])
                if item != recentlyClosed[index] { recentlyClosed[index] = item }
            }
        }
    }

    // MARK: The gate

    public func reviewState(_ id: String) -> ReviewState {
        ReviewGate.resolve(record: record(id), history: histories[id], pond: pond,
                           served: served[id]?.payload.instructable)
    }

    /// The revision the card and detail render; nil for a legacy ask or a failed history.
    public func renderedStamp(_ id: String) -> RevisionStamp? {
        ReviewGate.renderedStamp(reviewState(id), history: try? histories[id]?.get())
    }

    public func isContentLocked(_ id: String) -> Bool { reviewState(id).isLocked }

    func record(_ id: String) -> ReviewRecord? {
        reviews[ReviewStore.key(sourceKey: sourceKey, id: id)]
    }

    func setRecord(_ record: ReviewRecord?, for id: String) {
        reviews[ReviewStore.key(sourceKey: sourceKey, id: id)] = record
    }

    /// Pins every verified stamp the record doesn't have yet, for rollback detection only.
    /// A history that already breaks a pin keeps the old pins, and pinning never sets `seen`.
    /// With the seal refused the pins still hold for this run, in memory only (the save is
    /// skipped): an ask seen with a revision that comes back without one fails closed.
    func pin(_ id: String) {
        guard case .success(let history)? = histories[id] else { return }
        var next = record(id) ?? ReviewRecord()
        guard RevisionCheck.checkPins(history, pins: next.pins) == nil else { return }
        var changed = false
        for (rev, stamp) in history.stamps where next.pins[rev] == nil {
            next.pins[rev] = stamp.hash
            changed = true
        }
        if let first = history.stamps[1], next.pins[1] == first.hash, let body = history.body(first) {
            let hash = ReviewGate.bodyHash(body)
            if next.firstBodyHash != hash {
                next.firstBodyHash = hash
                changed = true
            }
        }
        guard changed else { return }
        setRecord(next, for: id)
        scheduleReviewSave()
    }

    /// The detail rendered `stamp` while it was current: the owner saw it. Called from the
    /// snapshot builder, so it publishes nothing.
    func markSeen(_ id: String, _ stamp: RevisionStamp) {
        guard !reviewsUnreadable, case .current(let current) = reviewState(id), current == stamp else { return }
        var next = record(id) ?? ReviewRecord()
        guard next.seen != stamp else { return }
        next.seen = stamp
        setRecord(next, for: id)
        scheduleReviewSave()
    }

    /// The connected Pond's version, from the version check. A change renders every ask again.
    public func setPond(_ version: PondVersion?) {
        guard pond != version else { return }
        objectWillChange.send()
        pond = version
        let ids = Set(listed.map(\.id)).union(details.keys).union(recentlyClosed.map(\.id))
        holdingQueue { ids.forEach(rerender) }
    }

    /// After a good list: the records of this source's asks still listed, in Recently closed or
    /// open are marked listed today. One that left them goes at once only without pins; a pinned
    /// one is rollback evidence the Pond could erase by leaving the ask out of one list, so it
    /// goes only after `ReviewRecord.retentionDays` days unlisted.
    func pruneReviews(keep: Set<String>) {
        guard !reviewsUnreadable else { return }
        let prefix = ReviewStore.key(sourceKey: sourceKey, id: "")
        let today = ReviewRecord.day(now())
        var changed = false
        for (key, record) in reviews where key.hasPrefix(prefix) {
            if keep.contains(String(key.dropFirst(prefix.count))) || (!record.pins.isEmpty && record.listedDay == nil) {
                guard record.listedDay != today else { continue }
                reviews[key]?.listedDay = today
                changed = true
            } else if record.pins.isEmpty || today - (record.listedDay ?? today) > ReviewRecord.retentionDays {
                reviews[key] = nil
                changed = true
            }
        }
        if changed { scheduleReviewSave() }
    }

    // MARK: Review content

    /// The review of a pending ask: one cumulative diff from this Mac's accepted (else seen)
    /// revision, or the full content when this Mac never showed it; every reason after the
    /// baseline. nil when the ask isn't pending or its fetched history isn't at hand yet.
    public func reviewDiff(_ id: String) -> RevisionDiff? { reviewDiff(id, to: nil) }

    /// The same, up to `target` (a verified revision above the baseline) instead of the current one.
    func reviewDiff(_ id: String, to target: RevisionStamp?) -> RevisionDiff? {
        guard case .pending(let shown, let current, let baseline) = reviewState(id),
              case .success(let history)? = histories[id], history.isComplete,
              let first = history.bodies[1], let now = history.body(target ?? current) else { return nil }
        let from = baseline ?? 1
        let upTo = (target ?? current).rev
        guard upTo > from else { return nil }
        let reasons = (from + 1...upTo).compactMap { rev in
            history.reasons[rev].flatMap { $0.isEmpty ? nil : (rev: rev, reason: $0) }
        }
        return RevisionDiff.make(baseline: shown.flatMap(history.body), firstRevision: first, current: now,
                                 reasons: reasons)
    }

    /// The review's "Look closer" flags, over what changed since the baseline (all of it on a first view).
    public func lookCloserFlags(_ id: String) -> [LookCloserFlag] { lookCloserFlags(id, to: nil) }

    func lookCloserFlags(_ id: String, to target: RevisionStamp?) -> [LookCloserFlag] {
        guard case .pending(let shown, let current, _) = reviewState(id), case .success(let history)? = histories[id],
              let now = history.body(target ?? current) else { return [] }
        return LookCloser.flags(old: shown.flatMap(history.body), new: now, cwd: now.from?.cwd)
    }

    // MARK: The inline review

    /// The inline review of the version `reviewing` names (else the current one): nil when the
    /// ask isn't pending, or its full history hasn't arrived yet.
    public func reviewPage(_ id: String) -> ReviewPage? {
        guard case .pending(_, let current, let baseline) = reviewState(id),
              case .success(let history)? = histories[id] else { return nil }
        let target = reviewing[id].flatMap { history.stamps[$0.rev] == $0 && $0.rev <= current.rev ? $0 : nil } ?? current
        guard let body = history.body(target), let diff = reviewDiff(id, to: target) else { return nil }
        return ReviewPage.make(diff: diff, flags: lookCloserFlags(id, to: target), body: body, target: target,
                               latest: current, baselineRev: baseline,
                               time: { history.times[$0].map { ClockText.time($0) } ?? "" })
    }

    /// While a correction is pending: the shown version's tags (`RevisionDiff.shownChips`).
    func pendingChips(_ id: String) -> [String: StepChip] {
        reviewDiff(id)?.shownChips ?? [:]
    }

    /// Steps the pending correction adds, for the locked detail's "2 steps added" line.
    func addedSinceShown(_ id: String, review: ReviewState) -> Int {
        guard case .pending = review, let diff = reviewDiff(id), !diff.isFirstView else { return 0 }
        return diff.addedIDs.count
    }

    // MARK: Trust again, and the review Notices

    /// After a Pond restore: with the owner's presence, every ask whose history verifies now
    /// has its pins cleared and is pinned again as served. An ask whose history fails its own
    /// checks, or isn't loaded, keeps its pins: nothing here can make a bad hash good, or drop
    /// the evidence of a rollback that hasn't been shown again.
    @discardableResult public func trustHistoryAgain() async -> Bool {
        guard await shell.confirmPresence("trust the Pond's history again") else { return false }
        if reviewsUnreadable { retryReviewKey() }
        guard !reviewsUnreadable else {
            post(.reviewRecordsUnreadable)
            return false
        }
        let verified = histories.compactMap { id, history in
            if case .success = history { return id } else { return nil }
        }
        for id in verified {
            guard var next = record(id) else { continue }
            next.pins = [:]
            next.firstBodyHash = nil
            setRecord(next, for: id)
        }
        holdingQueue {
            for id in verified {
                pin(id)
                rerender(id)
            }
        }
        saveReviewsNow()
        if case .historyChanged? = notice { dismissNotice() }
        reviewNoticed = [:]
        if let selected = navigation.selectedID { noticeReview(selected) }
        queueInputChanged()
        objectWillChange.send()
        return true
    }

    /// The open ask's review Notice, posted once per state: "Corrected after you saw it" for a
    /// correction to a revision this Mac showed, the red history Notice for a failed history.
    /// The review entry point never depends on it (`DetailSnapshot.reviewAction`).
    func noticeReview(_ id: String) {
        let state = reviewState(id)
        guard reviewNoticed[id] != state else { return }
        reviewNoticed[id] = state
        switch state {
        case .pending(let shown?, let current, _) where shown.rev < current.rev:
            post(.corrected(id: id, rev: current.rev))
        case .historyChanged:
            post(.historyChanged(id: id))
        case .legacy, .current, .pending:
            switch notice {
            case .corrected(let noticed, _)? where noticed == id: dismissNotice()
            case .historyChanged(let noticed)? where noticed == id: dismissNotice()
            default: break
            }
        }
    }

    // MARK: Report a problem

    /// One step's problem, on the revision this Mac renders (the Pond takes the current or the
    /// accepted one). Allowed while locked: it reports on the version shown. Needs the owner key,
    /// so without an approved one nothing is sent.
    public func reportProblem(_ id: String, stepID: String, note: String) async -> ReportResult {
        guard ownerKeyApproved(sourceKey, identity.mailbox?.url) else { return .notEnrolled }
        let cleaned = ProblemReport.clean(note)
        guard ProblemReport.canSend(cleaned) else {
            return .refused("The note must be 1 to \(ProblemReport.limit) characters.")
        }
        guard let source, let stamp = renderedStamp(id) else {
            return .refused("This ask comes from a Pond without problem reports.")
        }
        let gen = generation
        do {
            _ = try await source.problem(id, stepID: stepID, stamp: stamp, note: cleaned)
            guard gen == generation else { return .sent }
            await reload(id)
            return .sent
        } catch {
            guard gen == generation else { return .refused(ProblemReport.refusal(error)) }
            if ownerKeyRefused(error) { return .notEnrolled }
            return .refused(ProblemReport.refusal(error))
        }
    }

    /// The paths with a report the step hasn't been corrected since ("Reported · waiting for a correction").
    func reported(_ id: String) -> Set<String> {
        guard let events = details[id]?.events, events.contains(where: { $0.kind == "problem" }) else { return [] }
        return ProblemReport.reported(events: events, history: try? histories[id]?.get(),
                                      rendered: item(for: id)?.instructable, renderedRev: renderedStamp(id)?.rev)
    }

    // MARK: Chips

    /// "Changed" and "New" by path in the rendered tree, while the accepted revision is current;
    /// "Changed" and "Removed" on the shown version while a correction is pending.
    func chips(_ id: String, review: ReviewState) -> [String: StepChip] {
        if case .pending = review { return pendingChips(id) }
        guard case .current = review, let record = record(id), !record.changed.isEmpty,
              let ins = item(for: id)?.instructable else { return [:] }
        let paths = StepIdentity.paths(ins)
        var chips: [String: StepChip] = [:]
        for stepID in record.changed {
            guard let path = stepID == "verify" ? (ins.verify == nil ? nil : "verify") : paths[stepID] else { continue }
            chips[path] = record.added.contains(stepID) ? .new : .changed
        }
        return chips
    }

    /// Ticking a step ends its chip.
    func clearChips(_ id: String, ticked: Set<String>) {
        guard !ticked.isEmpty, !reviewsUnreadable, var next = record(id),
              !ticked.isDisjoint(with: next.changed) else { return }
        next.changed.removeAll { ticked.contains($0) }
        next.added.removeAll { ticked.contains($0) }
        setRecord(next, for: id)
        scheduleReviewSave()
    }

    // MARK: Persistence

    /// At launch: the seal key, then the records that still verify. A refused Keychain read, or a
    /// seal item Hook didn't make (`.foreign`, also any item while `reviews.json` or its marker
    /// is gone), loads nothing and writes nothing until the owner resets the records; a failed
    /// write of a new key keeps records in memory only.
    func loadReviews() {
        guard let reviewFile else { return }
        let key: SymmetricKey
        let hadFile = FileManager.default.fileExists(atPath: reviewFile.url.path)
        do {
            let seal = try ReviewSeal.open(reviewFile.secrets, file: reviewFile.url)
            key = seal.key
            // A file whose seal item is gone was set aside with its records.
            if seal.created, hadFile { pendingReviewNotice = .reviewRecordsChanged }
        } catch SecretStoreError.unreadable, SecretStoreError.foreign {
            // A refused read, or a key Hook didn't make, whose maker could seal records: trust
            // none, and replace nothing (Reset Review Records… is the owner's).
            reviewsUnreadable = true
            pendingReviewNotice = .reviewRecordsUnreadable
            return
        } catch {
            NSLog("Hook: couldn't save the review seal key; reviews stay in memory: %@", error.localizedDescription)
            return
        }
        sealKey = key
        let loaded = ReviewStore.load(from: reviewFile.url, sealKey: key)
        let inMemory = reviews
        reviews = Self.joiningPins(loaded.records, inMemory)
        if loaded.tampered {
            pendingReviewNotice = .reviewRecordsChanged
        }
        if loaded.tampered || reviews != loaded.records { scheduleReviewSave() }
    }

    /// Reset Review Records…: with the owner's presence, a new seal over whatever item is there,
    /// and the records start again from this run's pins. Every correction needs a review again,
    /// and each owner key, marked under the old seal, has to be set up again.
    @discardableResult public func resetReviewRecords() async -> Bool {
        guard let reviewFile, reviewsUnreadable,
              await shell.confirmPresence("reset Hook's review records") else { return false }
        let key: SymmetricKey
        do {
            key = try ReviewSeal.create(reviewFile.secrets, file: reviewFile.url)
        } catch {
            NSLog("Hook: couldn't reset the review records: %@", error.localizedDescription)
            return false
        }
        sealKey = key
        reviewsUnreadable = false
        reviews = Self.joiningPins([:], reviews)
        saveReviewsNow()
        holdingQueue {
            for id in histories.keys { rerender(id) }
        }
        post(.reviewRecordsChanged)
        onReviewRecordsReset?()
        queueInputChanged()
        objectWillChange.send()
        return true
    }

    /// The records on disk, with the pins taken in memory while the seal was refused added: a
    /// rev the disk already pins keeps the disk's hash, so a clash still reads as changed history.
    static func joiningPins(_ disk: [String: ReviewRecord], _ memory: [String: ReviewRecord]) -> [String: ReviewRecord] {
        var out = disk
        for (key, record) in memory where !record.pins.isEmpty {
            var next = out[key] ?? ReviewRecord()
            next.pins.merge(record.pins) { onDisk, _ in onDisk }
            if next.firstBodyHash == nil, next.pins[1] == record.pins[1] { next.firstBodyHash = record.firstBodyHash }
            out[key] = next
        }
        return out
    }

    /// One save at the end of this main-actor turn, however many records changed in it.
    func scheduleReviewSave() {
        guard reviewFile != nil, sealKey != nil, !reviewSaveScheduled else { return }
        reviewSaveScheduled = true
        Task { @MainActor [weak self] in self?.saveReviewsNow() }
    }

    /// Writes `reviews.json` now. False when nothing may be written, or the write failed.
    @discardableResult func saveReviewsNow() -> Bool {
        reviewSaveScheduled = false
        guard let reviewFile, let sealKey, !reviewsUnreadable else { return false }
        do {
            try PrivateFile.write(ReviewStore.sealed(records: reviews, sealKey: sealKey), to: reviewFile.url)
            return true
        } catch {
            NSLog("Hook: couldn't save the review records: %@", error.localizedDescription)
            return false
        }
    }
}
