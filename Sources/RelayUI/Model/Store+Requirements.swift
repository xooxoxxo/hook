import Foundation
import RelayCore

/// Required steps before Done (Pond 1.3.0): the Done gate, and this Mac's ticks sent to the Pond
/// as progress, so its 409 and Telegram's Done see them.
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

    /// Adds tick changes to the ask's outbox and restarts its debounce. Only for an ask that
    /// declares requirements, on a source that may take progress.
    func queueProgress(_ id: String, tick: [String], untick: [String]) {
        guard !tick.isEmpty || !untick.isEmpty, progressSupport != false,
              Requirements.declared(item(for: id)?.instructable) else { return }
        var delta = progressOutbox[id] ?? ProgressDelta()
        delta.add(tick: tick, untick: untick)
        progressOutbox[id] = delta.isEmpty ? nil : delta
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
        while let running = progressSends[id] {
            await running.task.value
            if progressSends[id]?.token == running.token { progressSends[id] = nil }
        }
        guard let delta = progressOutbox[id], !delta.isEmpty else { return true }
        guard progressSupport == true, let source else { return false }
        progressOutbox[id] = nil
        let gen = generation
        let stamp = renderedStamp(id)
        let token = UUID()
        let task = Task { [weak self] in
            do {
                _ = try await source.progress(id, tick: delta.tick.sorted(), untick: delta.untick.sorted(), stamp: stamp)
            } catch {
                guard let self, gen == self.generation else { return }
                if case QueueError.rejected(400, _, _)? = error as? QueueError { return }
                var back = delta
                if let later = self.progressOutbox[id] { back.add(later) }
                self.progressOutbox[id] = back.isEmpty ? nil : back
            }
        }
        progressSends[id] = (token, task)
        await task.value
        if progressSends[id]?.token == token { progressSends[id] = nil }
        return progressOutbox[id] == nil
    }

    /// After a detail load: the ticks the Pond lists as left that this Mac has go again (RD 11,
    /// 13), and an outbox a failed send left behind gets another try.
    func catchUpProgress(_ id: String) {
        if let pond = details[id]?.item.requirements, !pond.ready, let nodes = nodes(for: id) {
            queueProgress(id, tick: Requirements.behind(pond.left, nodes: nodes, ticks: ticks(for: id)), untick: [])
        }
        if progressOutbox[id] != nil, progressTimers[id] == nil, progressSends[id] == nil { scheduleProgress(id) }
    }

    /// The version check answered: a Pond with progress gets what waited, any other source never will.
    func progressSupportChanged() {
        switch progressSupport {
        case true?: progressOutbox.keys.forEach(scheduleProgress)
        case false?: resetProgress()
        case nil: break
        }
    }

    /// A source swap or an older Pond: nothing waiting is sent.
    func resetProgress() {
        progressTimers.values.forEach { $0.cancel() }
        progressTimers = [:]
        progressOutbox = [:]
    }
}

/// What an ask's requirement state is built from: change counters for its cached detail and
/// verified history, and its ticks. Equal inputs give the same state.
struct RequirementInputs: Equatable {
    var detail: Int
    var history: Int
    var ticks: Set<String>
}
