import Foundation

/// The panel's two pieces of navigation state (design §4.6): the highlighted row
/// and the open detail. Pure, so every rule here is tested without views.
public struct PanelNavigation: Equatable, Sendable {
    public var listSelection: String?
    /// The ask open in the detail; nil shows the list.
    public var selectedID: String?

    public init(listSelection: String? = nil, selectedID: String? = nil) {
        self.listSelection = listSelection
        self.selectedID = selectedID
    }

    /// `listed` is false for an ask outside the filter: the row you came from stays selected.
    public mutating func open(_ id: String, listed: Bool = true) {
        selectedID = id
        if listed { listSelection = id }
    }

    public mutating func back() {
        selectedID = nil
    }

    /// On appear and when the panel becomes key: keep a shown selection, else the first row.
    public mutating func settle(visibleOrder: [String], closedOrder: [String]) {
        if let current = listSelection, visibleOrder.contains(current) || closedOrder.contains(current) { return }
        listSelection = visibleOrder.first
    }

    public mutating func filterChanged(visibleOrder: [String], closedOrder: [String]) {
        settle(visibleOrder: visibleOrder, closedOrder: closedOrder)
    }

    /// `visibleOrder` is the order before the close hid `id`.
    public mutating func afterClose(_ id: String, visibleOrder: [String], setting: AfterClose, inDetail: Bool) {
        let next = Flow.nextAsk(after: id, in: visibleOrder)
        if inDetail, setting == .next, let next {
            selectedID = next
            listSelection = next
            return
        }
        if inDetail { selectedID = nil }
        listSelection = next
    }

    /// Undo brought `id` back: select it if it shows and no other ask's detail is open.
    public mutating func undoRestored(_ id: String, visibleOrder: [String]) {
        guard selectedID == nil, visibleOrder.contains(id) else { return }
        listSelection = id
    }

    public func neighbours(of id: String, visibleOrder: [String], closedOrder: [String]) -> (previous: Neighbour, next: Neighbour) {
        for order in [visibleOrder, closedOrder] {
            guard let index = order.firstIndex(of: id) else { continue }
            let previous: Neighbour = index > 0 ? .ask(order[index - 1]) : .end
            let next: Neighbour = index + 1 < order.count ? .ask(order[index + 1]) : .end
            return (previous, next)
        }
        return (.outsideFilter, .outsideFilter)
    }
}
