import Foundation
import RelayCore

/// Required steps before Done (Pond 1.3), plus shared ticks on every ask (Pond 1.5).
/// Older Ponds retain the Mac's local tick and requirements catch-up behavior.
extension Store {
    // MARK: The gate

    /// Done may be pressed for `id` (the button, ⌘↩, the context menu): the ask declares no
    /// requirements, or its cached detail says nothing is left but what the unsent drafts finish
    /// (RD 22). Without a cached detail an ask with requirements can't be Done (RD 23).
    public func doneAllowed(_ id: String) -> Bool {
        guard let state = requirementState(id) else { return true }
        guard let state else { return false }
        return Requirements.doneAvailable(state, unsent: unsentAnswers(for: id), replyUnsent: replyUnsent(id))
    }

    /// Nothing is left without the drafts: what `close(.done)` and Discard & Done need.
    func requirementsMet(_ id: String) -> Bool {
        guard let state = requirementState(id) else { return true }
        return state?.ready ?? false
    }

    /// nil: the ask declares no requirements. `.some(nil)`: it does, but no detail is cached.
    /// The state is cached by `RequirementInputs`: a queue rebuild with the ask's detail,
    /// history and ticks unchanged builds no model.
    private func requirementState(_ id: String) -> RequirementState?? {
        guard let item = item(for: id), Requirements.declared(item.instructable) else { return nil }
        guard let detail = details[id] else { return .some(nil) }
        let ticks = ticks(for: id)
        let inputs = RequirementInputs(detail: detailVersions[id] ?? 0, history: historyVersions[id] ?? 0, ticks: ticks)
        if let cached = requirementCache[id], cached.inputs == inputs { return .some(cached.state) }
        let model = DetailModel.make(item: detail.item, events: detail.events, history: try? histories[id]?.get())
        requirementModelBuilds += 1
        let state = Requirements.state(model, ticks: ticks)
        requirementCache[id] = (inputs, state)
        return .some(state)
    }

    /// The reply field holds text or a pick that isn't sent.
    private func replyUnsent(_ id: String) -> Bool {
        Flow.unsentKind(draft: drafts[id], choice: pendingChoice[id], sent: latestSentChoice(for: id),
                        sentText: AnswerEditing.latestText(replyLines(for: id)), newWords: replyHasNewWords(id)) == .reply
    }

    /// The Pond refused the Done with 409 requirements_unmet (RD 28): a Notice that names no
    /// item, the detail again, and the ticks the Pond lacks sent again. No automatic retry.
    func doneRefused(_ close: PendingClose, left: [PondRequirement], via source: any QueueSource,
                     generation gen: Int) async {
        post(.doneRefused(id: close.id, title: close.title))
        await reload(close.id)
        guard gen == generation else { return }
        guard deliveryPolicy == .desktop, sharedProgressSupport == false else { return }
        let behind = Requirements.behind(left, nodes: nodes(for: close.id) ?? [], ticks: ticks(for: close.id))
        queueProgress(close.id, tick: behind, untick: [])
    }

    // MARK: The version wait

    /// Returns once the Pond's version is known (`pond` is set), or after `timeout`, or at a
    /// source swap; at once when it is already known. Done's send waits here right after launch.
    func waitForPond(timeout: Duration) async {
        guard pond == nil else { return }
        let token = UUID(), sleep = timeoutSleep
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timer = Task { [weak self] in
                await sleep(timeout)
                self?.resumePondWaiter(token)
            }
            pondWaiters[token] = (continuation, timer)
        }
    }

    private func resumePondWaiter(_ token: UUID) {
        guard let waiter = pondWaiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume()
    }

    /// The version check answered, or the source swapped: every Done waiting goes on.
    func resumePondWaiters() {
        let all = pondWaiters
        pondWaiters = [:]
        for waiter in all.values {
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    /// Bumps `versions[id]` for each id whose value differs between `old` and `new`.
    static func bumpChanged<Value: Equatable>(_ versions: inout [String: Int], old: [String: Value],
                                              new: [String: Value]) {
        for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
            versions[id, default: 0] += 1
        }
    }

    // MARK: Progress

    /// This source takes progress: a Pond of 1.3.0 or later; nil while its version check hasn't
    /// answered (the outbox waits), false for This Mac or an older Pond (never sent, no Notice).
    var progressSupport: Bool? {
        guard sourceKey.hasPrefix("mailbox:") else { return false }
        guard let pond else { return nil }
        return pond.supports(.requirements)
    }

    /// nil until the version arrives; older Ponds retain their local Mac semantics.
    var sharedProgressSupport: Bool? {
        guard sourceKey.hasPrefix("mailbox:") else { return false }
        return pond.map { $0.supports(.sharedProgress) }
    }

    /// Match the raw body of the displayed, verified stamp. Typed Step omits
    /// unknown fields, so it cannot establish the identity of a local action.
    private func progressIdentity(_ id: String) -> [String: JSONValue]? {
        if let stamp = renderedStamp(id) {
            guard case .success(let history)? = histories[id], history.body(stamp) != nil,
                  RevisionCheck.checkPins(history, pins: record(id)?.pins ?? [:]) == nil else { return nil }
            let retained = sharedProgressDetails[id]?.revisions.first { $0.stamp == stamp }?.body
            let listed = served[id]?.revision.flatMap { $0.stamp == stamp ? $0.body : nil }
            guard let body = retained ?? listed, let json = try? JSONValue.parse(Data(body.utf8)) else { return nil }
            return SharedProgress.stepIdentities(in: json)
        }
        guard histories[id] == nil, served[id]?.revision == nil,
              served[id]?.revisionMetadataMalformed != true else { return nil }
        guard let body = sharedProgressDetails[id]?.item.payload.instructableJSON
                ?? served[id]?.payload.instructableJSON else { return nil }
        return SharedProgress.stepIdentities(in: body)
    }

    private func sharedBase(_ id: String) -> Set<String> {
        let identity = progressIdentity(id)
        let authoritative = sharedProgressValues[id]
        var ticks: Set<String> = []
        ProgressOverlay(delta: ProgressDelta(tick: authoritative?.ticks ?? []), identity: authoritative?.identity)
            .apply(to: &ticks, identity: identity)
        for overlay in progressOverlays[id] ?? [] { overlay.apply(to: &ticks, identity: identity) }
        return ticks
    }

    func sharedTicks(_ id: String, item: WireItem) -> Set<String> {
        var ticks = sharedBase(id)
        if let delta = progressOutbox[id] {
            ProgressOverlay(delta: delta, identity: progressIdentities[id]).apply(to: &ticks, identity: progressIdentity(id))
        }
        return Set(Flow.items(of: stepTree(item)).filter { $0.stepID.map(ticks.contains) ?? false }.map(\.path))
    }

    /// A late response must not roll back either the event log or the accepted revision.
    func staleProgressDetail(_ detail: AskDetail) -> Bool {
        let id = detail.item.id
        let old = sharedProgressDetails[id]
        let seenRevision = max(old?.item.revision?.rev ?? 0, served[id]?.revision?.rev ?? 0)
        if (detail.item.revision?.rev ?? 0) < seenRevision { return true }
        if (detail.item.revision?.acceptedRev ?? 1) < (old?.item.revision?.acceptedRev ?? 1) { return true }
        return (detail.events.map(\.seq).max() ?? 0) < (old?.events.map(\.seq).max() ?? 0)
    }

    func receiveSharedProgress(_ raw: AskDetail, confirmed: Set<UUID>) {
        let id = raw.item.id
        guard let ticks = try? SharedProgress.fold(detail: raw) else { return }
        if case .success(let history)? = histories[id],
           RevisionCheck.checkPins(history, pins: record(id)?.pins ?? [:]) != nil { return }
        var body = raw.item.payload.instructableJSON
        if raw.item.revision != nil {
            guard case .success(let history)? = histories[id],
                  let revision = raw.revisions.first(where: { $0.rev == history.acceptedOnPond }),
                  let accepted = try? JSONValue.parse(Data(revision.body.utf8)) else { return }
            body = accepted
        }
        sharedProgressDetails[id] = raw
        sharedProgressValues[id] = (ticks, body.map(SharedProgress.stepIdentities) ?? [:])
        guard sharedProgressSupport == true else { return }
        TickStore.adoptShared(defaults, sourceKey: sourceKey)
        progressOverlays[id]?.removeAll { confirmed.contains($0.token) }
        progressConfirmed[id]?.subtract(confirmed)
        tickCache[id] = nil
    }

    /// Adds current local tick changes to the outbox and restarts its debounce.
    /// Before 1.5, only asks declaring requirements send progress.
    func queueProgress(_ id: String, tick: [String], untick: [String]) {
        guard !tick.isEmpty || !untick.isEmpty, progressSupport != false,
              sharedProgressSupport != false || Requirements.declared(item(for: id)?.instructable) else { return }
        var delta = progressOutbox[id] ?? ProgressDelta()
        if sharedProgressSupport == true {
            delta = ProgressOverlay(delta: delta, identity: progressIdentities[id]).filtered(identity: progressIdentity(id))
        }
        if sharedProgressSupport == true, item(for: id) != nil {
            // Keep the latest intent relative to the current server/in-flight base.
            // A remote tick arriving during the debounce must not cancel a new untick.
            delta.tick.subtract(untick)
            delta.untick.subtract(tick)
            delta.tick.formUnion(tick)
            delta.untick.formUnion(untick)
            let base = sharedBase(id)
            delta.tick.subtract(base)
            delta.untick.formIntersection(base)
        } else {
            delta.add(tick: tick, untick: untick)
        }
        progressOutbox[id] = delta.isEmpty ? nil : delta
        progressIdentities[id] = progressIdentity(id)
        scheduleProgress(id)
    }

    /// Sends the outbox after `DS.Timing.progressDebounce`, unless a newer tick comes first. Not
    /// while the ask is locked for review: the Pond would refuse it as corrected, and the next
    /// detail load after the review sends it.
    func scheduleProgress(_ id: String) {
        progressTimers.removeValue(forKey: id)?.cancel()
        guard progressOutbox[id] != nil, progressSupport == true, !isContentLocked(id) else { return }
        let gen = generation
        progressTimers[id] = Task { [weak self, sleep] in
            try? await sleep(.seconds(DS.Timing.progressDebounce))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.progressTimers[id] = nil
            await self.flushProgress(id)
        }
    }

    /// Sends the ask's outbox now, after any send in flight, bound to the revision shown. A
    /// failure keeps it for the next tick, refresh or Done, with no Notice; a delta the Pond
    /// refuses as invalid (400) would be refused again, so it goes.
    @discardableResult func flushProgress(_ id: String) async -> Bool {
        progressTimers.removeValue(forKey: id)?.cancel()
        let gen = generation
        while let running = progressSends[id] {
            await running.task.value
            guard gen == generation else { return false }
            if progressSends[id]?.token == running.token { progressSends[id] = nil }
        }
        if sharedProgressSupport == true, let delta = progressOutbox[id] {
            let filtered = ProgressOverlay(delta: delta, identity: progressIdentities[id]).filtered(identity: progressIdentity(id))
            progressOutbox[id] = filtered.isEmpty ? nil : filtered
        }
        guard let delta = progressOutbox[id], !delta.isEmpty else { return true }
        guard mutationsAvailable, progressSupport == true, let source else { return false }
        progressOutbox[id] = nil
        let stamp = renderedStamp(id)
        let token = UUID()
        let shared = sharedProgressSupport == true
        let sentIdentity = progressIdentities[id]
        if shared {
            progressOverlays[id, default: []].append(ProgressOverlay(token: token, delta: delta, identity: sentIdentity))
        }
        let task = Task { [weak self] in
            do {
                _ = try await source.progress(id, tick: delta.tick.sorted(), untick: delta.untick.sorted(), stamp: stamp)
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                if shared {
                    self.progressConfirmed[id, default: []].insert(token)
                    await self.reload(id)
                }
            } catch {
                guard let self, gen == self.generation else { return }
                self.progressOverlays[id]?.removeAll { $0.token == token }
                self.tickCache[id] = nil
                if self.deliveryPolicy == .phone {
                    self.post(.deliveryFailed(reason: Self.failureReason(error)))
                    return
                }
                if case QueueError.rejected(400, _, _)? = error as? QueueError { return }
                var back = shared
                    ? ProgressOverlay(delta: delta, identity: sentIdentity).filtered(identity: self.progressIdentity(id))
                    : delta
                if let later = self.progressOutbox[id] {
                    if shared {
                        back.tick.subtract(later.untick)
                        back.untick.subtract(later.tick)
                        back.tick.formUnion(later.tick)
                        back.untick.formUnion(later.untick)
                    } else { back.add(later) }
                }
                self.progressOutbox[id] = back.isEmpty ? nil : back
            }
        }
        progressSends[id] = (token, task)
        await task.value
        guard gen == generation else { return false }
        if progressSends[id]?.token == token { progressSends[id] = nil }
        return progressOutbox[id] == nil
    }

    /// Older Ponds catch up device-local required ticks. Shared-progress Ponds
    /// only retry the current outbox; receiving remote ticks never queues a send.
    func catchUpProgress(_ id: String) {
        guard deliveryPolicy == .desktop else { return }
        if sharedProgressSupport == false, let pond = details[id]?.item.requirements, !pond.ready, let nodes = nodes(for: id) {
            queueProgress(id, tick: Requirements.behind(pond.left, nodes: nodes, ticks: ticks(for: id)), untick: [])
        }
        if progressOutbox[id] != nil, progressTimers[id] == nil, progressSends[id] == nil { scheduleProgress(id) }
    }

    /// The version check answered: a Pond with progress gets what waited, any other source never will.
    func progressSupportChanged() {
        switch progressSupport {
        case true?:
            if sharedProgressSupport == true {
                if !sharedProgressDetails.isEmpty { TickStore.adoptShared(defaults, sourceKey: sourceKey) }
                tickCache = [:]
            } else {
                progressOutbox = progressOutbox.filter { Requirements.declared(item(for: $0.key)?.instructable) }
                // Version discovery held legacy catch-up; only an older Pond may
                // now receive the ticks it says are missing from requirements.
                details.keys.forEach(catchUpProgress)
            }
            progressOutbox.keys.forEach(scheduleProgress)
        case false?: resetProgress()
        case nil: break
        }
    }

    /// A source swap or an older Pond: nothing waiting is sent.
    func resetProgress() {
        progressTimers.values.forEach { $0.cancel() }
        progressTimers = [:]
        progressOutbox = [:]
        progressSends.values.forEach { $0.task.cancel() }
        progressSends = [:]
        progressOverlays = [:]
        progressConfirmed = [:]
        progressIdentities = [:]
        sharedProgressDetails = [:]
        sharedProgressValues = [:]
    }
}

/// What an ask's requirement state is built from: change counters for its cached detail and
/// verified history, and its ticks. Equal inputs give the same state.
struct RequirementInputs: Equatable {
    var detail: Int
    var history: Int
    var ticks: Set<String>
}

/// A delta acts only on the same step content the owner ticked. A correction may
/// toggle required or move a step, but changing its command invalidates the tick.
struct ProgressOverlay {
    var token = UUID()
    var delta: ProgressDelta
    var identity: [String: JSONValue]?

    func filtered(identity current: [String: JSONValue]?) -> ProgressDelta {
        guard let identity, let current else { return ProgressDelta() }
        let valid = Set(current.keys.filter { identity[$0] != nil && identity[$0] == current[$0] })
        return ProgressDelta(tick: delta.tick.intersection(valid), untick: delta.untick.intersection(valid))
    }

    func apply(to ticks: inout Set<String>, identity current: [String: JSONValue]?) {
        let delta = filtered(identity: current)
        ticks.formUnion(delta.tick)
        ticks.subtract(delta.untick)
    }
}
