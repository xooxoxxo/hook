import RelayCore
import RelayUI
import SwiftUI

/// A fixture queue with nothing listed, showing `content`.
@MainActor func stateQueue(_ content: PanelContent) -> QueueSnapshot {
    var queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)
    queue.content = content
    queue.title = "Queue"
    queue.sections = []
    queue.rows = [:]
    queue.closed = []
    queue.hidden = .zero
    queue.projects = []
    return queue
}

/// Filtered to a project with no asks while the other projects keep theirs.
@MainActor func filteredEmptyQueue() -> QueueSnapshot {
    let project = "Atlas"
    var queue = stateQueue(.emptyFiltered(project: project))
    queue.filter = project
    queue.hidden = QueueLayout.hiddenCount(items: GalleryFixtures.open, filter: project)
    queue.projects = QueueLayout.menuProjects(items: GalleryFixtures.open, filter: project)
    return queue
}

@MainActor let stateScenes: [GalleryScene] = [
    panelScene("state-loading", queueModel(stateQueue(.loading(stillTrying: false)),
               status: PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: false, loadedOnce: false)))),
    panelScene("state-empty", queueModel(stateQueue(.empty))),
    panelScene("state-empty-filtered", queueModel(filteredEmptyQueue())),
    panelScene("state-offline", queueModel(stateQueue(.offline(local: false, reason: offlineReason)),
               status: offlineStatus(loadedOnce: false))),
    panelScene("state-notsetup", queueModel(stateQueue(.notSetUp),
               status: PanelStatus.make(StatusInputs(sourceKey: SourceKey.none, reachable: false, loadedOnce: false)))),
    panelScene("state-notfound", FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        navigation: PanelNavigation(selectedID: "00000000-0000-4000-8000-0000000000ff"),
        status: readyStatus)),
]
