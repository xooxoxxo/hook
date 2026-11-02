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
        served[raw.id] = raw
        listedHistories[raw.id] = RevisionCheck.verify(listed: raw)
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

    /// Opens only under `copyCode`'s rule, and only a web URL a step or link of the rendered revision names.
    public func openStepURL(_ id: String, stamp: RevisionStamp?, url: URL) {
        guard actsOnShown(id, stamp: stamp), LinkDisplay.isWeb(url.absoluteString) else { return }
        let steps = (nodes(for: id).map(Flow.flattened) ?? []).compactMap(\.url)
        let links = (item(for: id)?.instructable?.links ?? []).compactMap(\.url)
        guard (steps + links).contains(where: { URL(string: $0) == url }) else { return }
        shell.openURL(url)
    }

    /// The ask is unlocked and `stamp` is the revision it renders now.
    func actsOnShown(_ id: String, stamp: RevisionStamp?) -> Bool {
        switch reviewState(id) {
        case .legacy: return stamp == nil
        case .current(let current): return stamp == current && renderedStamp(id) == current
        case .pending, .historyChanged: return false
        }
    }

    /// A failed act's reason; a correction that raced the act reads "the ask was corrected".
    static func failureReason(_ error: any Error) -> String {
        if case QueueError.corrected? = error as? QueueError { return "the ask was corrected" }
        return UserFacingError.text(error)
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
        ReviewGate.resolve(record: record(id), history: histories[id], pond: pond)
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
    func pin(_ id: String) {
        guard !reviewsUnreadable, case .success(let history)? = histories[id] else { return }
        var next = record(id) ?? ReviewRecord()
        guard RevisionCheck.checkPins(history, pins: next.pins) == nil else { return }
        var changed = false
        for (rev, stamp) in history.stamps where next.pins[rev] == nil {
            next.pins[rev] = stamp.hash
            changed = true
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

    /// Drops the records of this source's asks that left the list, Recently closed and the detail.
    func pruneReviews(keep: Set<String>) {
        let prefix = ReviewStore.key(sourceKey: sourceKey, id: "")
        let gone = reviews.keys.filter { $0.hasPrefix(prefix) && !keep.contains(String($0.dropFirst(prefix.count))) }
        guard !gone.isEmpty, !reviewsUnreadable else { return }
        gone.forEach { reviews[$0] = nil }
        scheduleReviewSave()
    }

    // MARK: Chips

    /// "Changed" and "New" by path in the rendered tree, while the accepted revision is current.
    func chips(_ id: String, review: ReviewState) -> [String: StepChip] {
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

    /// At launch: the seal key, then the records that still verify. A refused Keychain read
    /// loads nothing and writes nothing; a failed write of a new key keeps records in memory only.
    func loadReviews() {
        guard let reviewFile else { return }
        let key: SymmetricKey
        do {
            key = try ReviewSeal.loadOrCreate(reviewFile.secrets)
        } catch SecretStoreError.unreadable {
            reviewsUnreadable = true
            pendingReviewNotice = .reviewRecordsUnreadable
            return
        } catch {
            NSLog("Hook: couldn't save the review seal key; reviews stay in memory: %@", error.localizedDescription)
            return
        }
        sealKey = key
        let loaded = ReviewStore.load(from: reviewFile.url, sealKey: key)
        reviews = loaded.records
        if loaded.tampered {
            pendingReviewNotice = .reviewRecordsChanged
            scheduleReviewSave()
        }
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
