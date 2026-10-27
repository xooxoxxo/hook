import RelayCore
import RelayUI
import SwiftUI

// Step questions: each scene is one small ask, so the question block is the subject.
// Generic text only: the Kestrel project and example.com.

private let answersCreated = "2026-10-16T08:40:00+00:00"

private let environment = Question(prompt: "Which environment?", choices: ["Staging", "Prod"])
private let region = Question(prompt: "Where should the nightly backups be kept?",
                              choices: ["Europe (Frankfurt)", "North America (Virginia)", "Asia Pacific (Singapore)"])
private let flags = Question(prompt: "Which feature flags go on with this release?",
                             choices: ["Search", "Exports", "Dark mode"], multi: true)
private let releaseName = Question(prompt: "What should the release be called?\nIt shows on the download page.")
private let shipToday = Question(prompt: "Ship it today?", choices: ["Yes", "No"])

private func answersItem(_ id: String, _ title: String, steps: [Step], status: String = "open",
                         completedAt: String? = nil, reply: ReplySpec? = nil) -> WireItem {
    WireItem(id: id, title: title, status: status, projectId: "Kestrel", created: answersCreated, updated: answersCreated,
             payload: Payload(why: nil, cmd: nil, link: nil,
                              instructable: Instructable(v: 1, title: title, urgency: "today", steps: steps, reply: reply)),
             completedAt: completedAt)
}

/// One owner reply event; a choice travels as "choice: X".
private func replyEvent(_ id: String, seq: Int, _ text: String, at: String) -> Event {
    Event(seq: seq, itemId: id, kind: "reply", actor: "owner", text: text, at: at)
}

/// One owner `answer` event, as the mailbox stores it (R2).
private func answerEvent(_ id: String, seq: Int, _ entry: JSONValue) -> Event {
    Event(seq: seq, itemId: id, kind: "answer", actor: "owner", text: String(decoding: entry.data(), as: UTF8.self),
          at: "2026-10-16T09:12:00+00:00")
}

/// A detail scene for `item` with `events`, the drafts in both the snapshot and the model.
@MainActor private func answersScene(_ name: String, _ item: WireItem, events: [Event] = [], ticks: Set<String> = [],
                                     drafts: [String: AnswerDraft] = [:], closedText: String? = nil,
                                     height: CGFloat? = nil, expanded: Set<String> = [], editing: Set<String> = [],
                                     doneWarning: Bool = false,
                                     setUp: (FixturePanelModel, String) -> Void = { _, _ in },
                                     overrides: PanelGalleryOverrides = fullHeight) -> GalleryScene {
    var snapshot = DetailSnapshot.build(
        item: item, detail: AskDetail(item: item, events: events), ticks: ticks, load: .loaded, reply: .idle,
        draft: nil, pendingChoice: nil, busy: false, previous: .end, next: .end, closedBy: nil, answerDrafts: drafts,
        doneWarning: doneWarning)
    snapshot.replies = ReplyText.lines(events: events, locale: galleryGB, timeZone: galleryUTC)
    if let closedText {
        snapshot.closedText = closedText
    }
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    if !drafts.isEmpty { model.answerDrafts[snapshot.id] = drafts }
    if !expanded.isEmpty { model.expandedDone[snapshot.id] = expanded }
    if !editing.isEmpty { model.editingAnswers[snapshot.id] = editing }
    setUp(model, snapshot.id)
    return panelScene(name, model, height: height, rules: topColumnRules,
                      overrides: height == nil ? overrides : PanelGalleryOverrides(now: GalleryFixtures.now))
}

/// A segmented pick nobody has answered: the current step, no segment selected.
@MainActor private var segmentedScene: GalleryScene {
    let item = answersItem("kestrel-q1", "Deploy the Kestrel release", steps: [
        Step(action: "Pick the deploy target", question: environment),
        Step(action: "Run the deploy", place: "Mac terminal", code: "kestrel deploy"),
    ])
    return answersScene("answers-segmented", item)
}

/// A radio pick, answered (from a Telegram tap or this Mac): done, with "You chose".
@MainActor private var radioScene: GalleryScene {
    let item = answersItem("kestrel-q2", "Choose the backup region", steps: [
        Step(action: "Pick the backup region", question: region),
        Step(action: "Turn on the nightly backup", url: "https://console.example.com/backups"),
    ])
    let events = [answerEvent(item.id, seq: 1, Answers.entry(step: "1", picked: ["Europe (Frankfurt)"]))]
    return answersScene("answers-radio-answered", item, events: events)
}

/// A multi pick answered "Search", with "Exports" ticked since: "Not sent" beside its own Send.
@MainActor private var multiScene: GalleryScene {
    let item = answersItem("kestrel-q3", "Turn on the release flags", steps: [
        Step(action: "Choose the flags", place: "Flags dashboard", question: flags),
        Step(action: "Check the flags page", url: "https://flags.example.com/kestrel"),
    ])
    let events = [answerEvent(item.id, seq: 1, Answers.entry(step: "1", picked: ["Search"]))]
    return answersScene("answers-multi-not-sent", item, events: events, drafts: ["1": .picked(["Search", "Exports"])])
}

/// A free-text answer, sent; the field starts from it.
@MainActor private var textScene: GalleryScene {
    let item = answersItem("kestrel-q4", "Name the Kestrel release", steps: [
        Step(action: "Name the release", question: releaseName),
        Step(action: "Publish the download page", url: "https://downloads.example.com/kestrel"),
    ])
    let events = [answerEvent(item.id, seq: 1, Answers.entry(step: "1", text: "Kestrel 2.4, the spring cleaning release"))]
    return answersScene("answers-free-text", item, events: events)
}

/// A parent with its own question, above its sub-steps; the question is current.
@MainActor private var parentScene: GalleryScene {
    let item = answersItem("kestrel-q5", "Roll out Kestrel 2.4", steps: [
        Step(action: "Prepare the rollout", place: "Release dashboard", substeps: [
            Step(action: "Tag the build", code: "git tag v2.4.0", lang: "bash"),
            Step(action: "Post in the release channel"),
        ], question: shipToday),
        Step(action: "Start the rollout", url: "https://release.example.com/kestrel"),
    ])
    return answersScene("answers-parent", item)
}

private func barItem() -> WireItem {
    answersItem("kestrel-q6", "Set up the Kestrel release", steps: [
        Step(action: "Pick the deploy target", question: environment),
        Step(action: "Choose the flags", question: flags),
        Step(action: "Name the release", question: releaseName),
    ])
}

private let barDrafts: [String: AnswerDraft] = ["1": .picked(["Staging"]), "2": .picked(["Search", "Dark mode"])]

/// Three questions, two drafted: each block has its own Send; the bar is Skip and Done.
@MainActor private var barScene: GalleryScene {
    answersScene("answers-bar", barItem(), drafts: barDrafts, height: 820)
}

/// answers-bar after Done: the bar's warning, "You have an unsent answer", Discard & Done
/// and Send & Done (⌘↩).
@MainActor private var barWarningScene: GalleryScene {
    answersScene("answers-bar-warning", barItem(), drafts: barDrafts, height: 820, doneWarning: true)
}

/// A closed ask: read-only, the answered line or "Not answered", no controls (R5).
@MainActor private var closedScene: GalleryScene {
    let at = "2026-10-16T09:20:00+00:00"
    let item = answersItem("kestrel-q7", "Deploy the Kestrel release", steps: [
        Step(action: "Pick the deploy target", question: environment),
        Step(action: "Name the release", question: releaseName),
    ], status: "done", completedAt: at)
    let events = [answerEvent(item.id, seq: 1, Answers.entry(step: "1", picked: ["Prod"]))]
    let closedText = ClosedText.detail(status: "done", closedBy: "owner", closedAt: at, locale: galleryGB, timeZone: galleryUTC)
    return answersScene("answers-closed", item, events: events, closedText: closedText)
}

/// The radio pick answered and its done row opened: the prompt on one line, "You chose: … ·
/// 09:12" and Change.
@MainActor private var answeredScene: GalleryScene {
    let item = answersItem("kestrel-q8", "Choose the backup region", steps: [
        Step(action: "Pick the backup region", question: region),
        Step(action: "Turn on the nightly backup", url: "https://console.example.com/backups"),
    ])
    let events = [answerEvent(item.id, seq: 1, Answers.entry(step: "1", picked: ["Europe (Frankfurt)"]))]
    return answersScene("answers-answered", item, events: events, expanded: ["1"])
}

/// The same after Change, with another region picked: the rows, Cancel and Send.
@MainActor private var changingScene: GalleryScene {
    let item = answersItem("kestrel-q9", "Choose the backup region", steps: [
        Step(action: "Pick the backup region", question: region),
        Step(action: "Turn on the nightly backup", url: "https://console.example.com/backups"),
    ])
    let events = [answerEvent(item.id, seq: 1, Answers.entry(step: "1", picked: ["Europe (Frankfurt)"]))]
    return answersScene("answers-changing", item, events: events, drafts: ["1": .picked(["Asia Pacific (Singapore)"])],
                        expanded: ["1"], editing: ["1"])
}

private let regionReply = ReplySpec(prompt: "Which region should the backups use from now on?",
                                    choices: ["Europe", "North America", "Asia Pacific"])

/// Three replies to an ask with choices: the latest as the answer row with Change, the two
/// earlier ones under History (open).
@MainActor private var replyAnsweredScene: GalleryScene {
    let item = answersItem("kestrel-r1", "Choose the backup region", steps: [
        Step(action: "Read the backup cost sheet", url: "https://console.example.com/costs"),
    ], reply: regionReply)
    let events = [
        replyEvent(item.id, seq: 1, ReplyText.wire(choice: "Europe"), at: "2026-10-16T08:50:00+00:00"),
        replyEvent(item.id, seq: 2, "Hold off until the cost sheet is updated", at: "2026-10-16T09:05:00+00:00"),
        replyEvent(item.id, seq: 3, ReplyText.wire(choice: "North America"), at: "2026-10-16T09:20:00+00:00"),
    ]
    var overrides = fullHeight
    overrides.historyExpanded = true
    return answersScene("reply-answered", item, events: events, ticks: ["1"], overrides: overrides)
}

/// A free-text reply after Change: the field holds the sent text (Send stays off until it
/// changes), the note and Cancel under it.
@MainActor private var replyChangingScene: GalleryScene {
    let item = answersItem("kestrel-r2", "Name the Kestrel release", steps: [
        Step(action: "Read the release notes", url: "https://downloads.example.com/kestrel/notes"),
    ], reply: ReplySpec(prompt: "What should the release be called?"))
    let events = [replyEvent(item.id, seq: 1, "Kestrel 2.4", at: "2026-10-16T09:20:00+00:00")]
    return answersScene("reply-changing", item, events: events, ticks: ["1"], setUp: { model, id in model.changeReply(id) })
}

@MainActor var answerScenes: [GalleryScene] {
    [segmentedScene, radioScene, multiScene, textScene, parentScene, barScene, barWarningScene, closedScene,
     answeredScene, changingScene, replyAnsweredScene, replyChangingScene]
}
