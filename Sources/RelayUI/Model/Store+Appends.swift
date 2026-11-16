import Foundation
import RelayCore

/// Steps the session added at the end of an open ask: the card's "+N steps" until the owner
/// opens the ask, and one notification.
extension Store {
    /// After a fetched detail: the appends the Store hadn't seen for `id` yet. Never on the
    /// first look at an ask, and once per marker. An ask open in the detail shows them already.
    func noteAppends(_ id: String) {
        let fresh = appendWatch.observe(id, markers: appendMarkers(id))
        guard !fresh.isEmpty, let item = item(for: id), item.status == "open" else { return }
        let count = fresh.map(\.addedTopLevel).reduce(0, +)
        if navigation.selectedID != id {
            updateUnseenAppends { $0.added(id, steps: count) }
        }
        if let content = NotifyContent.stepsAdded(item, markers: fresh, events: details[id]?.events ?? [], now: now()) {
            onStepsAdded?(item, content)
        }
    }

    /// Applies a change, saving it and rebuilding the queue only when the counts moved.
    func updateUnseenAppends(_ change: (inout UnseenAppends) -> Void) {
        var next = unseenAppends
        change(&next)
        guard next != unseenAppends else { return }
        unseenAppends = next
        next.save(defaults)
        queueInputChanged()
    }
}

/// `then: "steps"`: after the owner answers that question, Done waits for the session's next
/// steps (a new revision) or 10 minutes. Skip always works.
extension Store {
    /// The wait on now for an open ask whose detail is fetched. A Pond that lists `appendSteps`
    /// decides from the single-item route (the detail's `stepWait`); an older one, the rule here.
    public func stepWait(_ id: String) -> StepWait? {
        guard let detail = details[id], detail.item.status == "open", let ins = detail.item.instructable else { return nil }
        let history = try? histories[id]?.get()
        let times = history.map { history in history.times.sorted { $0.key < $1.key }.map(\.value) } ?? []
        return StepWait.current(ins, events: detail.events, revisionTimes: times, now: now(),
                                pond: detail.item.stepWait.flatMap(StepWait.init),
                                pondServesWaits: pondCapabilities?.supports(.appendSteps) == true)
    }

    /// After a fetched detail: one re-render at the wait's end, so Done comes back without a
    /// poll. A detail without a wait (a new revision ended it) cancels it.
    func scheduleStepWait(_ id: String) {
        let until = stepWait(id)?.until
        guard stepWaitUntil[id] != until || (until != nil && stepWaitTimers[id] == nil) else { return }
        stepWaitTimers.removeValue(forKey: id)?.cancel()
        stepWaitUntil[id] = until
        guard let until else { return }
        let sleep = timeoutSleep, delay = max(0, until.timeIntervalSince(now()))
        stepWaitTimers[id] = Task { [weak self] in
            await sleep(.milliseconds(Int64((delay * 1000).rounded(.up))))
            guard !Task.isCancelled, let self, self.stepWaitUntil[id] == until else { return }
            self.stepWaitTimers[id] = nil
            self.stepWaitUntil[id] = nil
            self.stateTick += 1
        }
    }
}
