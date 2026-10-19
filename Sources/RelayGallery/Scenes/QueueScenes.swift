import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The gallery's mailbox source key (generic host, never a real one).
let galleryMailboxKey = "mailbox:mailbox.example:8790#personal"

/// "Mailbox · ready", from the same logic the app uses.
let readyStatus = PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: true, loadedOnce: true))

/// A 380 pt panel scene rendered through `PanelRoot`, on the fixed gallery clock.
@MainActor func panelScene(_ name: String, _ model: FixturePanelModel, height: CGFloat? = 820,
                           rules: [AlignmentRule] = []) -> GalleryScene {
    panelScene(name, model, height: height, rules: rules, overrides: PanelGalleryOverrides(now: GalleryFixtures.now))
}

/// The same, with gallery overrides (closed group or From expanded, full-height detail).
@MainActor func panelScene(_ name: String, _ model: FixturePanelModel, height: CGFloat?,
                           rules: [AlignmentRule], overrides: PanelGalleryOverrides) -> GalleryScene {
    GalleryScene(
        name: name, size: .panel(height: height), standIn: true, rules: rules,
        view: { AnyView(PanelRoot(model: model).environment(\.panelGallery, overrides)) },
        appKit: nil)
}

/// The §3.5 queue edge check: text on the gutter, counts and summaries on the trailing edge.
let queueEdgeRules: [AlignmentRule] = [
    .leading(.gutterText, x: DS.Space.gutter, tolerance: 1),
    .trailing(.trailingEdge, x: DS.Metric.panelWidth - DS.Space.gutter, tolerance: 2),
]

/// A fixture model over `queue`, with the second visible row selected (the selected-row look).
@MainActor func queueModel(_ queue: QueueSnapshot, notice: PanelNotice? = nil, undo: UndoInfo? = nil,
                           status: PanelStatus = readyStatus) -> FixturePanelModel {
    let order = QueueLayout.visibleOrder(queue.sections)
    let selected = order.dropFirst().first ?? order.first
    return FixturePanelModel(queue: queue, navigation: PanelNavigation(listSelection: selected),
                             notice: notice, undo: undo, status: status)
}

/// The longest project name in the 12-project fixture (60 characters).
@MainActor var longProjectName: String {
    GalleryFixtures.manyProjects.map { $0.projectId ?? "" }.max { $0.count < $1.count } ?? ""
}

/// The 12-project fixture as a queue snapshot, built with the same layout logic the Store uses.
@MainActor func limitsQueue(filter: String?) -> QueueSnapshot {
    let items = GalleryFixtures.manyProjects
    var queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)
    queue.grouping = .project
    queue.filter = filter
    queue.sections = QueueLayout.sections(items: items, grouping: .project, filter: filter)
    queue.rows = Dictionary(uniqueKeysWithValues: items.map { item in
        (item.id, AskRowModel(id: item.id, title: item.title, project: item.projectId ?? "",
                              urgency: Urgency(raw: item.instructable?.urgency), created: item.created,
                              summary: QueueLayout.summary(for: item, ticked: [])))
    })
    queue.closed = []
    queue.hidden = QueueLayout.hiddenCount(items: items, filter: filter)
    queue.projects = QueueLayout.menuProjects(items: items, filter: filter)
    let shown = QueueLayout.visibleOrder(queue.sections).count
    queue.title = shown == 0 ? "Queue" : "\(shown) waiting"
    queue.content = .list
    return queue
}

/// A project whose filter hides a "now" ask in another project (computed, so it follows the fixture).
@MainActor var hiddenNowFilter: String {
    QueueLayout.menuProjects(items: GalleryFixtures.open, filter: nil).map(\.name).first {
        QueueLayout.hiddenCount(items: GalleryFixtures.open, filter: $0).now > 0
    } ?? "Relay"
}

@MainActor let queueScenes: [GalleryScene] = [
    panelScene("queue", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)),
               rules: queueEdgeRules),
    panelScene("queue-urgency", queueModel(GalleryFixtures.queue(grouping: .urgency, filter: nil, closedExpanded: false)),
               rules: queueEdgeRules),
    panelScene("queue-closed-open", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: true)),
               height: 820, rules: queueEdgeRules,
               overrides: PanelGalleryOverrides(now: GalleryFixtures.now, closedExpanded: true)),
    panelScene("queue-limits", queueModel(limitsQueue(filter: nil)), height: 1400, rules: queueEdgeRules),
    panelScene("queue-limits-filtered", queueModel(limitsQueue(filter: longProjectName)), rules: queueEdgeRules),
    panelScene("queue-filtered", queueModel(GalleryFixtures.queue(grouping: .urgency, filter: "Acme", closedExpanded: false)),
               rules: queueEdgeRules),
    panelScene("queue-filtered-project", queueModel(GalleryFixtures.queue(grouping: .project, filter: "Acme", closedExpanded: true)),
               height: 820, rules: queueEdgeRules,
               overrides: PanelGalleryOverrides(now: GalleryFixtures.now, closedExpanded: true)),
    panelScene("queue-filtered-hidden-now", queueModel(GalleryFixtures.queue(grouping: .project, filter: hiddenNowFilter, closedExpanded: false)),
               rules: queueEdgeRules),
]
