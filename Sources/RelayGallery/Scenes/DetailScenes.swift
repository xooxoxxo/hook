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

/// The fixture's step ask before its detail arrives: no model yet (as `DetailSnapshot.build`
/// makes it with `detail: nil`), so the header and title come from the row and the steps
/// area shows `load`: "Loading steps…" or, after the timeout, "Couldn't load this ask."
@MainActor func unloadedDetail(_ load: DetailLoadState) -> DetailSnapshot {
    var snapshot = GalleryFixtures.detailSteps
    snapshot.model = nil
    snapshot.load = load
    snapshot.ticks = []
    snapshot.current = Flow.currentStep(ticks: [], nodes: [])
    snapshot.progress = Flow.progress(ticks: [], nodes: [])
    snapshot.replies = []
    return snapshot
}

/// Not found, but the ask is in Recently closed, so "Show Closed Ask" is offered.
/// Without it is "state-notfound" (StateScenes).
@MainActor func notFoundClosedModel() -> FixturePanelModel {
    let queue = GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false)
    let id = queue.closed.first?.id ?? "acme-c1"
    return FixturePanelModel(queue: queue, navigation: PanelNavigation(selectedID: id), status: readyStatus)
}

/// The detail-steps column check: markers on one centre per level, text on one edge per level.
let stepColumnRules: [AlignmentRule] = [
    .sameCentre(.topMarker, tolerance: 1),
    .sameCentre(.subMarker, tolerance: 1),
    .sameLeading(.topActionText, tolerance: 1),
    .sameLeading(.subLabelText, tolerance: 1),
]

/// The same for scenes whose only parent is done and collapsed: no sub-step row is on screen,
/// and a rule with no probe fails.
let topColumnRules: [AlignmentRule] = [
    .sameCentre(.topMarker, tolerance: 1),
    .sameLeading(.topActionText, tolerance: 1),
]

let fullHeight = PanelGalleryOverrides(now: GalleryFixtures.now, fromExpanded: true, fullHeight: true)

/// `base` with every leaf before `path` ticked, so `path` is the current leaf.
func ticked(_ base: DetailSnapshot, before path: String) -> DetailSnapshot {
    var snapshot = base
    let nodes = base.model?.nodes ?? []
    snapshot.ticks = Set(Flow.leaves(of: nodes).prefix { $0.path != path }.map(\.path))
    snapshot.current = Flow.currentStep(ticks: snapshot.ticks, nodes: nodes)
    snapshot.progress = Flow.progress(ticks: snapshot.ticks, nodes: nodes)
    return snapshot
}

/// Every sub-step of step 2 ticked, step 1 too: the parent is done; 3 is current.
@MainActor var substepsDone: DetailSnapshot {
    ticked(GalleryFixtures.detailSteps, before: "3")
}

/// Hidden characters in a title, a place and a code block (they show as ⟨U+…⟩).
let hiddenCharsJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000000b1", "title": "Check the token\u202e name before saving",
  "status": "open", "projectId": "Northwind", "created": "2026-10-16T09:10:00+00:00", "updated": "2026-10-16T09:10:00+00:00",
  "payload": {"instructable": {"v": 1, "title": "Check the token\u202e name before saving", "urgency": "today",
    "why": "The pasted value had characters you can't see.",
    "steps": [{"do": "Run the check", "where": "Mac\u2066 terminal", "code": "echo token\u200b-ok", "expect": "token-ok"}]}}},
 "events": []}
"""#

/// Non-web and punycode links, as a step URL and in Links.
let nonWebLinksJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000000c1", "title": "Read the brief and the product page",
  "status": "open", "projectId": "Acme", "created": "2026-10-16T09:20:00+00:00", "updated": "2026-10-16T09:20:00+00:00",
  "payload": {"instructable": {"v": 1, "title": "Read the brief and the product page", "urgency": "whenever",
    "steps": [{"do": "Open the brief", "url": "ftp://files.example.com/brief.pdf"},
              {"do": "Open the product page", "url": "https://xn--bcher-kva.example.com/apps"}],
    "links": [{"label": "Brief", "url": "ftp://files.example.com/brief.pdf"},
              {"label": "Product page", "url": "https://xn--bcher-kva.example.com/apps"},
              {"label": "API docs", "url": "https://www.example.com/docs"}],
    "from": {"session": "1b2c3d4e-0000-4000-8000-000000000001", "host": "example-mac", "cwd": "/work/acme"}}}},
 "events": []}
"""#

@MainActor let detailScenes: [GalleryScene] = [
    detailScene("detail-legacy", detailSnapshot(decodeDetail(legacyJSON), base: GalleryFixtures.detailSteps)),
    detailScene("detail-closed", closedDetail, height: nil, overrides: fullHeight),
    detailScene("detail-session-closed", sessionClosedDetail, notice: .sessionClosed(id: sessionClosedDetail.id)),
    detailScene("detail-loading", unloadedDetail(.loading)),
    detailScene("detail-load-failed", unloadedDetail(.timedOut)),
    panelScene("detail-notfound-closed", notFoundClosedModel()),
    detailScene("detail-steps", GalleryFixtures.detailSteps, height: nil, rules: stepColumnRules, overrides: fullHeight),
    detailScene("detail-steps-current-4", ticked(GalleryFixtures.detailSteps, before: "4"), height: nil,
                rules: topColumnRules, overrides: fullHeight),
    detailScene("detail-substeps-done", substepsDone, height: nil, rules: topColumnRules, overrides: fullHeight),
    expandedSubstepsScene(),
    detailScene("detail-limits", GalleryFixtures.limits, height: nil, overrides: fullHeight),
    detailScene("detail-hidden-chars", detailSnapshot(decodeDetail(hiddenCharsJSON), base: GalleryFixtures.detailSteps),
                height: nil, overrides: fullHeight),
    detailScene("detail-links-nonweb", detailSnapshot(decodeDetail(nonWebLinksJSON), base: GalleryFixtures.detailSteps),
                height: nil, overrides: fullHeight),
    freeTypingScene(),
    choiceScene("detail-choice", sent: false),
    choiceScene("detail-choice-sent", sent: true),
    blockingScene(),
    unlockedScene(),
]

/// A blocking step with its warning box (current), a locked step after it, and a multi
/// question further down, locked too; a sub-step blocking its later sibling in step 5.
let blockingJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000000d1", "title": "Move the Kestrel site to the new host",
  "status": "open", "projectId": "Kestrel", "created": "2026-10-16T09:30:00+00:00", "updated": "2026-10-16T09:30:00+00:00",
  "payload": {"instructable": {"v": 1, "title": "Move the Kestrel site to the new host", "urgency": "today",
    "why": "The old host shuts down on Friday. Each step takes a minute or two.",
    "steps": [{"do": "Export the site backup", "code": "kestrel export > site.tar"},
              {"do": "Point the domain at the new host", "where": "DNS provider", "blocking": true,
               "detail": "Change the A record to the new address.",
               "warning": "Wait for DNS to update before going on: the next steps check the new host."},
              {"do": "Check the site loads over HTTPS", "url": "https://kestrel.example.com"},
              {"do": "Choose the features to turn back on",
               "question": {"prompt": "Which features go back on?", "choices": ["Search", "Comments", "Newsletter"], "multi": true}},
              {"do": "Retire the old host", "substeps": [
                {"do": "Download the old logs", "blocking": true},
                {"do": "Delete the old server"}]}]}}},
 "events": []}
"""#

/// blockingJSON with step 1 ticked: step 2 blocks and is current; 3 onwards are locked.
@MainActor func blockingScene() -> GalleryScene {
    var snapshot = detailSnapshot(decodeDetail(blockingJSON), base: GalleryFixtures.detailSteps, ticks: ["1"])
    snapshot.replies = []
    snapshot.model?.reply = nil
    return detailScene("detail-blocking", snapshot, height: nil, rules: topColumnRules, overrides: fullHeight)
}

/// detail-steps with a draft typed into its reply field: Done sends it first (the bar caption).
@MainActor func freeTypingScene() -> GalleryScene {
    var snapshot = GalleryFixtures.detailSteps
    let draft = "C0123ABCDEF"
    snapshot.primary = Flow.primaryAction(draft: draft, choice: nil, sent: nil)
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    model.drafts[snapshot.id] = draft
    // Full height, like the step scenes: at 820 pt the Reply section sits below the fold.
    return panelScene("detail-free-typing", model, height: nil, rules: [], overrides: fullHeight)
}

/// The choice fixture with the first choice picked; `sent` also marks it sent by a reply event.
@MainActor func choiceScene(_ name: String, sent: Bool) -> GalleryScene {
    var snapshot = GalleryFixtures.detailChoice
    let choices = snapshot.model?.reply?.choices ?? []
    if sent, let first = choices.first {
        snapshot.sentChoices = [0]
        snapshot.latestSentChoice = 0
        snapshot.replies = [ReplyLine(id: 1, text: ReplyText.display(ReplyText.wire(choice: first)), time: "09:12")]
    } else {
        snapshot.sentChoices = []
        snapshot.latestSentChoice = nil
        snapshot.replies = []
    }
    snapshot.primary = Flow.primaryAction(draft: nil, choice: 0, sent: snapshot.latestSentChoice)
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    model.pendingChoice[snapshot.id] = 0
    return panelScene(name, model, height: 820, rules: [], overrides: PanelGalleryOverrides(now: GalleryFixtures.now))
}

/// detail-substeps-done with the done parent expanded: expansion is memory-only model state.
@MainActor func expandedSubstepsScene() -> GalleryScene {
    let snapshot = substepsDone
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id),
        status: readyStatus)
    model.expandedDone[snapshot.id] = ["2"]
    return panelScene("detail-substeps-done-expanded", model, height: nil, rules: stepColumnRules, overrides: fullHeight)
}

/// The same ask past the block: 1–3 ticked, the multi question current with two picks
/// drafted, and step 5 opened by hand: its blocking sub-step 5a locks 5b.
@MainActor func unlockedScene() -> GalleryScene {
    var snapshot = detailSnapshot(decodeDetail(blockingJSON), base: GalleryFixtures.detailSteps, ticks: ["1", "2", "3"])
    snapshot.replies = []
    snapshot.model?.reply = nil
    let drafts: [String: AnswerDraft] = ["4": .picked(["Search", "Newsletter"])]
    snapshot.answerDrafts = drafts
    snapshot.primary = .sendAndDone
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    model.answerDrafts[snapshot.id] = drafts
    model.expandedTodo[snapshot.id] = ["5"]
    return panelScene("detail-blocking-unlocked", model, height: nil, rules: stepColumnRules, overrides: fullHeight)
}
