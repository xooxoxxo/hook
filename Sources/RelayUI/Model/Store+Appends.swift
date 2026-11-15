import Foundation
import RelayCore

/// Steps the session added at the end of an open ask: the card's "+N steps" until the owner
/// opens the ask.
extension Store {
    /// After a fetched detail: the appends the Store hadn't seen for `id` yet. Never on the
    /// first look at an ask, and once per marker. An ask open in the detail shows them already.
    func noteAppends(_ id: String) {
        let fresh = appendWatch.observe(id, markers: appendMarkers(id))
        guard !fresh.isEmpty, item(for: id)?.status == "open" else { return }
        let count = fresh.map(\.addedTopLevel).reduce(0, +)
        if navigation.selectedID != id {
            updateUnseenAppends { $0.added(id, steps: count) }
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
