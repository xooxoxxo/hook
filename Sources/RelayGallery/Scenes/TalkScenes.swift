import AppKit
import RelayCore
import RelayUI
import SwiftUI

// Talking to the posting session (0.12): Report a Problem on a step (pick 3 B) and the
// Messages section (pick 4 A). Generic text only.

/// A step ask with step ids (reports need them): step 1 done, step 2 current with code.
let reportStepsJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000012a1", "title": "Rotate the staging deploy key",
  "status": "open", "projectId": "Atlas", "created": "2026-10-16T07:40:00+00:00", "updated": "2026-10-16T07:40:00+00:00",
  "payload": {"instructable": {"v": 1, "title": "Rotate the staging deploy key", "urgency": "today",
    "why": "The old key expires on Friday and the deploy job will stop.",
    "steps": [{"id": "s1", "do": "Open the staging vault", "url": "https://vault.example.com/staging"},
              {"id": "s2", "do": "Generate a new deploy key", "where": "Mac terminal",
               "code": "ssh-keygen -t ed25519 -f ~/.ssh/atlas-deploy -C deploy@staging",
               "expect": "Your identification has been saved"},
              {"id": "s3", "do": "Paste the public key into the vault"}],
    "verify": {"do": "Check a dry-run deploy", "code": "atlas deploy --dry-run"},
    "from": {"session": "1b2c3d4e-0000-4000-8000-000000000001", "host": "example-mac", "cwd": "/work/atlas"}}}},
 "events": []}
"""#

/// The report fixture on a Pond: step 1 ticked, so step 2 is current and open.
@MainActor func reportSnapshot(target: String? = nil, reported: Set<String> = [], keyReady: Bool = true,
                               state: ReportBoxState = .idle) -> DetailSnapshot {
    var snapshot = detailSnapshot(decodeDetail(reportStepsJSON), base: GalleryFixtures.detailSteps, ticks: ["1"])
    snapshot.replies = []
    snapshot.model?.reply = nil
    snapshot.canReport = true
    snapshot.reportTarget = target
    snapshot.reported = reported
    snapshot.ownerKeyReady = keyReady
    snapshot.report = state
    return snapshot
}

@MainActor func reportScene(_ name: String, _ snapshot: DetailSnapshot) -> GalleryScene {
    detailScene(name, snapshot, height: nil, rules: topColumnRules, overrides: fullHeight)
}

/// An open ask with no reply prompt, from a Pond with messages; `messages` earlier ones.
let messageJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000012b1", "title": "Restart the build runner",
  "status": "open", "projectId": "Atlas", "created": "2026-10-16T08:10:00+00:00", "updated": "2026-10-16T08:10:00+00:00",
  "payload": {"instructable": {"v": 1, "title": "Restart the build runner", "urgency": "today",
    "why": "Builds have queued for an hour; the runner stopped picking them up.",
    "steps": [{"id": "s1", "do": "Open the runner page", "url": "https://ci.example.com/runners/2"},
              {"id": "s2", "do": "Restart the runner", "where": "Mac terminal", "code": "ci-runner restart --name runner-2"},
              {"id": "s3", "do": "Watch one build finish"}]
    REPLY,
    "from": {"session": "1b2c3d4e-0000-4000-8000-000000000001", "host": "example-mac", "cwd": "/work/atlas"}}}},
 "events": [EVENTS]}
"""#

let messageEvents = #"""
{"seq": 1, "itemId": "00000000-0000-4000-8000-0000000012b1", "kind": "message", "actor": "owner",
 "text": "Restarted it, but it says waiting for a lock.", "at": "2026-10-16T09:31:00+00:00", "rev": 1, "auth": "token"},
{"seq": 2, "itemId": "00000000-0000-4000-8000-0000000012b1", "kind": "message", "actor": "owner",
 "text": "The lock file is from yesterday.\nSafe to delete?", "at": "2026-10-16T09:33:00+00:00", "rev": 1, "auth": "token"}
"""#

/// The message fixture: `thread` adds two earlier messages, `reply` a reply prompt.
@MainActor func messageSnapshot(thread: Bool = false, reply: Bool = false, closed: Bool = false,
                                state: MessageBoxState = .idle) -> DetailSnapshot {
    let json = messageJSON
        .replacingOccurrences(of: "REPLY", with: reply ? #","reply": {"prompt": "Did the runner pick up the queue?", "choices": ["Yes", "No"]}"# : "")
        .replacingOccurrences(of: "[EVENTS]", with: thread ? "[" + messageEvents + "]" : "[]")
    var snapshot = detailSnapshot(decodeDetail(json), base: GalleryFixtures.detailSteps, ticks: ["1", "2"])
    snapshot.replies = []
    snapshot.messages = MessageText.lines(events: decodeDetail(json).events, locale: galleryGB, timeZone: galleryUTC)
    snapshot.canMessage = true
    snapshot.canReport = !closed
    snapshot.message = state
    if closed {
        let at = "2026-10-16T09:40:00+00:00"
        snapshot.closedText = ClosedText.detail(status: "done", closedBy: "session", closedAt: at,
                                                locale: galleryGB, timeZone: galleryUTC)
        snapshot.row.closed = ClosedInfo(status: "done", closedBy: "session", completedAt: at)
    }
    return snapshot
}

@MainActor func messageScene(_ name: String, _ snapshot: DetailSnapshot, draft: String? = nil,
                             expanded: Bool? = nil) -> GalleryScene {
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    model.messageDrafts[snapshot.id] = draft
    let overrides = PanelGalleryOverrides(now: GalleryFixtures.now, fromExpanded: false, fullHeight: true,
                                          locale: galleryGB, timeZone: galleryUTC, messagesExpanded: expanded)
    return panelScene(name, model, height: nil, rules: [], overrides: overrides)
}

/// A pasted log of exactly `count` characters, in lines, for the 8000 cap (Pond 1.4.0).
func pastedLog(_ count: Int) -> String {
    let line = "2026-10-16 09:31:04 runner-2 waiting for the build lock held by job 4417, retrying\n"
    let text = String(repeating: line, count: count / line.unicodeScalars.count + 1)
    return String(String.UnicodeScalarView(text.unicodeScalars.prefix(count)))
}

/// The message fixture on a Pond 1.4.0: 8000 characters.
@MainActor func longMessageSnapshot() -> DetailSnapshot {
    var snapshot = messageSnapshot()
    snapshot.limits = .long
    return snapshot
}

@MainActor let talkScenes: [GalleryScene] = [
    // Report on the current (open) step only; collapsed rows stay clean.
    reportScene("detail-step-report-open", reportSnapshot()),
    // The composer docked above the action bar, its step outlined.
    reportScene("detail-step-report-composer", reportSnapshot(target: "2")),
    // Step 1 reported: only the icon, no caption.
    reportScene("detail-step-reported", reportSnapshot(reported: ["1"])),
    // No approved owner key: Send reads Set Up Owner Key….
    reportScene("detail-step-report-no-key", reportSnapshot(target: "2", keyReady: false)),
    reportScene("detail-step-report-held", reportSnapshot(target: "2", keyReady: false, state: .held)),
    // Messages: the empty section with its field, a thread, behind the disclosure on an ask
    // with a reply prompt, a refusal, and a closed ask's read-only thread.
    messageScene("detail-messages-empty", messageSnapshot()),
    messageScene("detail-messages-thread", messageSnapshot(thread: true),
                 draft: "Deleting it now. Tell me if the queue starts moving."),
    messageScene("detail-messages-with-reply-prompt", messageSnapshot(thread: true, reply: true), expanded: true),
    messageScene("detail-messages-with-reply-prompt-closed", messageSnapshot(reply: true)),
    messageScene("detail-messages-refused", messageSnapshot(state: .failed(MessageText.secretRefused)),
                 draft: "The new key is in the vault under deploy, version 2."),
    messageScene("detail-messages-closed", messageSnapshot(thread: true, closed: true)),
    // 0.14 on Pond 1.4.0: past 80 % of 8000 the counter shows; over it the caption says how
    // much to trim and Send is off. The field grows to 8 lines, then scrolls.
    messageScene("talk-messages-long", longMessageSnapshot(), draft: pastedLog(7412)),
    messageScene("talk-messages-over", longMessageSnapshot(), draft: pastedLog(9204)),
]
