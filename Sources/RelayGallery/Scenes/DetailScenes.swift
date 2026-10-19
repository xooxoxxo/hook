import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Gallery fixture JSON → AskDetail (the scenes read like real mailbox payloads).
/// Generic text only.
func decodeDetail(_ json: String) -> AskDetail {
    do {
        return try JSONDecoder().decode(AskDetail.self, from: Data(json.utf8))
    } catch {
        fatalError("gallery fixture does not decode: \(error)")
    }
}

/// A snapshot for `detail`, built on `base` so the fields a scene doesn't set keep the fixture's.
func detailSnapshot(_ detail: AskDetail, base: DetailSnapshot, ticks: Set<String> = [],
                    closedText: String? = nil) -> DetailSnapshot {
    let model = DetailModel.make(detail)
    var snapshot = base
    snapshot.id = detail.item.id
    snapshot.model = model
    snapshot.load = .loaded
    snapshot.ticks = ticks
    snapshot.current = Flow.currentStep(ticks: ticks, nodes: model.nodes)
    snapshot.progress = Flow.progress(ticks: ticks, nodes: model.nodes)
    snapshot.row.id = detail.item.id
    snapshot.row.title = detail.item.title
    snapshot.row.project = detail.item.projectId ?? ""
    snapshot.row.urgency = Urgency(raw: detail.item.instructable?.urgency)
    snapshot.row.created = detail.item.created
    snapshot.replies = ReplyText.lines(events: detail.events, locale: Locale(identifier: "en_GB"),
                                       timeZone: TimeZone(identifier: "UTC")!)
    snapshot.closedText = closedText
    snapshot.previous = .end
    snapshot.next = .end
    return snapshot
}

/// A panel scene with `snapshot` open in the detail.
@MainActor func detailScene(_ name: String, _ snapshot: DetailSnapshot, notice: PanelNotice? = nil,
                            height: CGFloat? = 820, rules: [AlignmentRule] = [],
                            overrides: PanelGalleryOverrides = PanelGalleryOverrides(now: GalleryFixtures.now)) -> GalleryScene {
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id),
        notice: notice, status: readyStatus)
    return panelScene(name, model, height: height, rules: rules, overrides: overrides)
}

let galleryUTC = TimeZone(identifier: "UTC")!
let galleryGB = Locale(identifier: "en_GB")

let legacyJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000000a1", "title": "Check the version before the rotation",
  "status": "open", "projectId": "Atlas", "created": "2026-10-16T07:40:00+00:00", "updated": "2026-10-16T07:40:00+00:00",
  "payload": {"why": "The rotation script needs 0.5 or later.", "cmd": "relay --version"}},
 "events": [{"seq": 1, "itemId": "00000000-0000-4000-8000-0000000000a1", "kind": "steps", "actor": "session",
  "text": "Run it in any Terminal window. It prints one line.", "at": "2026-10-16T07:40:00+00:00"}]}
"""#

/// The fixture's step ask, closed by you at 06:12.
@MainActor var closedDetail: DetailSnapshot {
    var snapshot = GalleryFixtures.detailSteps
    let at = "2026-10-16T06:12:00+00:00"
    snapshot.closedText = ClosedText.detail(status: "done", closedBy: "owner", closedAt: at,
                                            locale: galleryGB, timeZone: galleryUTC)
    snapshot.row.closed = ClosedInfo(status: "done", closedBy: "owner", completedAt: at)
    return snapshot
}

/// The fixture's step ask, closed by the session while it was open.
@MainActor var sessionClosedDetail: DetailSnapshot {
    var snapshot = GalleryFixtures.detailSteps
    let at = "2026-10-16T09:12:00+00:00"
    snapshot.closedText = ClosedText.detail(status: "done", closedBy: "session", closedAt: at,
                                            locale: galleryGB, timeZone: galleryUTC)
    snapshot.row.closed = ClosedInfo(status: "done", closedBy: "session", completedAt: at)
    return snapshot
}

/// Not found, but the ask is in Recently closed, so "Show Closed Ask" is offered (§4.7;
/// controller ruling from Task 40). Without it is "state-notfound" (StateScenes).
@MainActor func notFoundClosedModel() -> FixturePanelModel {
    let queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)
    let id = queue.closed.first?.id ?? "acme-c1"
    return FixturePanelModel(queue: queue, navigation: PanelNavigation(selectedID: id), status: readyStatus)
}

@MainActor let detailScenes: [GalleryScene] = [
    detailScene("detail-legacy", detailSnapshot(decodeDetail(legacyJSON), base: GalleryFixtures.detailSteps)),
    detailScene("detail-closed", closedDetail),
    detailScene("detail-session-closed", sessionClosedDetail, notice: .sessionClosed(id: sessionClosedDetail.id)),
    panelScene("detail-notfound-closed", notFoundClosedModel()),
]
