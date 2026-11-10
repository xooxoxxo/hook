import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The gallery's mailbox source key (generic host, never a real one).
let galleryMailboxKey = "mailbox:mailbox.example:8790#personal"

/// "Pond" in green, from the same logic the app uses.
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

/// The gallery's offline reason (generic, the transport's own timeout wording).
let offlineReason = "The Pond didn't answer within 10 seconds."

/// "Offline" (or "Connecting…" before a first list), from the app's own logic.
func offlineStatus(loadedOnce: Bool) -> PanelStatus {
    PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: false, loadedOnce: loadedOnce, problem: offlineReason))
}

/// The queue edge check: section headers on the gutter with their counts on the trailing edge;
/// every card's edges `cardEdge` in from the panel's, its text `cardPadding` inside them.
let queueEdgeRules: [AlignmentRule] = queueFlatRules + [
    .trailing(.trailingEdge, x: DS.Metric.panelWidth - DS.Space.gutter, tolerance: 2),
]

/// The same for a flat queue (one project shown, Recently closed hidden): no section header,
/// so no count on the trailing edge; the header bar's title is still on the gutter.
let queueFlatRules: [AlignmentRule] = [
    .leading(.gutterText, x: DS.Space.gutter, tolerance: 1),
    .leading(.cardEdge, x: DS.Space.cardEdge, tolerance: 0.5),
    .trailing(.cardEdge, x: DS.Metric.panelWidth - DS.Space.cardEdge, tolerance: 0.5),
    .leading(.cardText, x: DS.Space.cardText, tolerance: 1),
    .trailing(.cardTrailing, x: DS.Metric.panelWidth - DS.Space.cardText, tolerance: 2),
]

/// A fixture model over `queue`, with the second visible row selected (the selected-row look).
@MainActor func queueModel(_ queue: QueueSnapshot, notice: PanelNotice? = nil, undo: UndoInfo? = nil,
                           status: PanelStatus = readyStatus, crashOffer: CrashOffer? = nil,
                           profiles: ProfileMenu? = nil) -> FixturePanelModel {
    let order = QueueLayout.visibleOrder(queue.sections)
    let selected = order.dropFirst().first ?? order.first
    return FixturePanelModel(queue: queue, navigation: PanelNavigation(listSelection: selected),
                             notice: notice, undo: undo, status: status, crashOffer: crashOffer, profiles: profiles)
}

/// The crash bar's two offers: a report ready, and a run that left only the log.
let galleryCrashOffer = CrashOffer(summary: GalleryFixtures.crash)
let galleryHangOffer = CrashOffer(summary: GalleryFixtures.hang)
/// A run that something else closed (0.14): "Hook was closed: SIGTERM from launchd (pid 1)".
let galleryClosedOffer = CrashOffer(summary: GalleryFixtures.closedRun)

/// The status bar's states over the plain queue, short enough to show the bottom bars.
@MainActor func statusScene(_ name: String, _ status: PanelStatus, profiles: ProfileMenu? = nil,
                            crashOffer: CrashOffer? = nil, undo: UndoInfo? = nil) -> GalleryScene {
    panelScene(name, queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
                                undo: undo, status: status, crashOffer: crashOffer, profiles: profiles),
               height: crashOffer == nil && undo == nil ? queueHeight : queueBarHeight, rules: queueEdgeRules)
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
                              summary: QueueLayout.summary(for: item, ticked: []), subline: SubLine.text(for: item)))
    })
    queue.closed = []
    queue.hidden = QueueLayout.hiddenCount(items: items, filter: filter)
    queue.projects = QueueLayout.menuProjects(items: items, filter: filter)
    let shown = QueueLayout.visibleOrder(queue.sections).count
    queue.title = "Queue"
    queue.waiting = shown
    queue.content = .list
    return queue
}

/// A project whose filter hides a "now" ask in another project (computed, so it follows the fixture).
@MainActor var hiddenNowFilter: String {
    QueueLayout.menuProjects(items: GalleryFixtures.open, filter: nil).map(\.name).first {
        QueueLayout.hiddenCount(items: GalleryFixtures.open, filter: $0).now > 0
    } ?? "Relay"
}

/// Tall enough for the whole fixture queue (Recently closed collapsed) above the bars at every
/// text size: a card cut off under the status bar would be measured through the bar.
let queueHeight: CGFloat = 960

/// The same with a bar docked above the status bar (the crash bar, Undo), which grows under --xl.
let queueBarHeight: CGFloat = 1080

/// The same with Recently closed open.
let queueClosedHeight: CGFloat = 1120

@MainActor let queueScenes: [GalleryScene] = [
    panelScene("queue", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)),
               height: queueHeight, rules: queueEdgeRules),
    panelScene("queue-urgency", queueModel(GalleryFixtures.queue(grouping: .urgency, filter: nil, closedExpanded: false)),
               height: queueHeight, rules: queueEdgeRules),
    panelScene("queue-closed-open", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: true)),
               height: queueClosedHeight, rules: queueEdgeRules,
               overrides: PanelGalleryOverrides(now: GalleryFixtures.now, closedExpanded: true)),
    // One project group collapsed (its header on a quiet fill, its cards hidden), the others open.
    panelScene("queue-collapsed", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)),
               height: queueHeight, rules: queueEdgeRules,
               overrides: PanelGalleryOverrides(now: GalleryFixtures.now, collapsedGroups: ["project:Acme"])),
    panelScene("queue-urgency-collapsed", queueModel(GalleryFixtures.queue(grouping: .urgency, filter: nil, closedExpanded: false)),
               height: queueHeight, rules: queueEdgeRules,
               overrides: PanelGalleryOverrides(now: GalleryFixtures.now, collapsedGroups: ["urgency:today"])),
    panelScene("queue-limits", queueModel(limitsQueue(filter: nil)), height: 1400, rules: queueEdgeRules),
    panelScene("queue-limits-filtered", queueModel(limitsQueue(filter: longProjectName)), rules: queueFlatRules),
    panelScene("queue-filtered", queueModel(GalleryFixtures.queue(grouping: .urgency, filter: "Acme", closedExpanded: false)),
               rules: queueEdgeRules),
    panelScene("queue-filtered-project", queueModel(GalleryFixtures.queue(grouping: .project, filter: "Acme", closedExpanded: true)),
               height: 820, rules: queueEdgeRules,
               overrides: PanelGalleryOverrides(now: GalleryFixtures.now, closedExpanded: true)),
    panelScene("queue-filtered-hidden-now", queueModel(GalleryFixtures.queue(grouping: .project, filter: hiddenNowFilter, closedExpanded: false)),
               rules: queueFlatRules),
    panelScene("queue-undo", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               undo: UndoInfo(verdict: .done, title: "Rotate the example token", deadline: Date().addingTimeInterval(8), more: 1)),
               height: queueBarHeight, rules: queueEdgeRules),
    panelScene("queue-closed-feedback", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               notice: .noLongerOpen(id: "gallery-closed", canShowClosed: true))),
    panelScene("queue-notice", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               notice: .actionFailed(verdict: .done, id: "gallery-failed", title: "Send the logo image", reason: offlineReason)),
               height: queueHeight, rules: queueEdgeRules),
    panelScene("queue-notice-mailbox-older", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               notice: .pondOlder(current: "1.0.0", required: PondCompat.required, missing: [.corrections])),
               height: queueHeight, rules: queueEdgeRules),
    panelScene("queue-notice-mailbox-newer", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               notice: .hookOlder(pond: "2.0.0")),
               height: queueHeight, rules: queueEdgeRules),
    panelScene("queue-notice-new-agents", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               notice: .newAgents(ids: ["cursor", "zed"], names: ["Cursor", "Zed"])),
               height: queueHeight, rules: queueEdgeRules),
    statusScene("queue-status-pond", readyStatus),
    statusScene("queue-status-offline", offlineStatus(loadedOnce: true)),
    statusScene("queue-status-local", PanelStatus.make(StatusInputs(sourceKey: SourceKey.local, reachable: true, loadedOnce: true)),
                profiles: FixturePanelModel.localProfiles),
    statusScene("queue-status-updating",
                PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: true, loadedOnce: true, updating: true))),
    statusScene("queue-crash-bar", readyStatus, crashOffer: galleryCrashOffer),
    statusScene("queue-crash-bar-closed", readyStatus, crashOffer: galleryClosedOffer),
    statusScene("queue-crash-bar-undo", readyStatus, crashOffer: galleryHangOffer,
                undo: UndoInfo(verdict: .done, title: "Rotate the example token", deadline: Date().addingTimeInterval(8), more: 0)),
    panelScene("queue-offline-stale", queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
               notice: .offlineCached(since: "09:22"), status: offlineStatus(loadedOnce: true)),
               height: queueHeight, rules: queueEdgeRules),
]
