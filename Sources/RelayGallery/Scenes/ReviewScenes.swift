import AppKit
import RelayCore
import RelayUI
import SwiftUI

// Step corrections: the locked ask, the inline review (Direction B), the history lock, and
// enrollment in Settings › Queue. The review is built by the real models (RevisionDiff,
// LookCloser, ReviewPage) from two versions of one ask, so the scenes show what Hook shows.

private let reviewID = "00000000-0000-4000-8000-0000000000c1"
private let reviewOrigin = Origin(session: "7f3a2c1e-5b6d-4e8f-9a0b-1c2d3e4f5a6b", host: "example-mac",
                                  cwd: "~/src/kestrel")

/// Version 1, the one this Mac accepted.
private let reviewV1 = Instructable(
    v: 1, title: "Rotate the staging deploy key",
    why: "The old key leaked into a build log. The runner can't deploy until it has the new one.", urgency: "today",
    steps: [
        Step(action: "Make a folder for the new key", code: "mkdir -p ~/keys/staging", id: "s1"),
        Step(action: "Make the new deploy key", code: "ssh-keygen -t ed25519 -f ~/keys/staging/deploy -C staging",
             id: "s2"),
        Step(action: "Upload the public key",
             code: "curl -fsS -X POST https://deploy.example.com/api/keys -F key=@~/keys/staging/deploy.pub", id: "s3"),
        Step(action: "Restart the runner", code: "kestrel runner restart", id: "s4"),
    ],
    verify: Step(action: "Check a deploy goes through", code: "kestrel deploy --dry-run"),
    from: reviewOrigin)

/// Version 3: step 3's host and path changed (v3), step 4 gained sudo and --all (v2), step 5 is new (v3).
private let reviewV3: Instructable = {
    var ins = reviewV1
    ins.steps[2].code = "curl -fsS -X POST https://deploy.example.net/api/v2/keys -F key=@~/keys/staging/deploy.pub"
    ins.steps[3] = Step(action: "Restart both runners", code: "sudo kestrel runner restart --all", id: "s4")
    ins.steps.append(Step(action: "Check the runner picked up the key", code: "kestrel runner status", id: "r3-1"))
    return ins
}()

private let reviewStamps = [1: RevisionStamp(rev: 1, hash: String(repeating: "a", count: 64)),
                            2: RevisionStamp(rev: 2, hash: String(repeating: "b", count: 64)),
                            3: RevisionStamp(rev: 3, hash: String(repeating: "c", count: 64))]
private let reviewReasons = [(rev: 2, reason: "The restart needs root on the new host, and --all restarts both runners."),
                             (rev: 3, reason: "The upload API moved to v2 on the .net domain last week. Added a status check.")]
private let reviewTimes = [1: "09:58", 2: "10:31", 3: "10:42"]

private let reviewDiff = RevisionDiff.make(baseline: reviewV1, firstRevision: reviewV1, current: reviewV3,
                                           reasons: reviewReasons)

/// The page the Store builds for this ask: version 3 under review, diffed from version 1.
private func reviewPage(latest: Int = 3) -> ReviewPage {
    ReviewPage.make(diff: reviewDiff, flags: LookCloser.flags(old: reviewV1, new: reviewV3, cwd: reviewOrigin.cwd),
                    body: reviewV3, target: reviewStamps[3]!,
                    latest: RevisionStamp(rev: latest, hash: String(repeating: "d", count: 64)), baselineRev: 1,
                    time: { reviewTimes[$0] ?? "10:50" })
}

/// A first view: this Mac never showed the ask, so version 3 is shown whole, untagged and
/// undimmed, with every Look-closer flag under its step.
private func firstViewPage() -> ReviewPage {
    let diff = RevisionDiff.make(baseline: nil, firstRevision: reviewV1, current: reviewV3, reasons: reviewReasons)
    return ReviewPage.make(diff: diff, flags: LookCloser.flags(old: nil, new: reviewV3, cwd: reviewOrigin.cwd),
                           body: reviewV3, target: reviewStamps[3]!, latest: reviewStamps[3]!, baselineRev: nil,
                           time: { reviewTimes[$0] ?? "10:50" })
}

private func reviewItem(_ ins: Instructable) -> WireItem {
    WireItem(id: reviewID, title: ins.title, status: "open", projectId: "Kestrel",
             created: "2026-10-16T09:20:00+00:00", updated: "2026-10-16T10:42:00+00:00",
             payload: Payload(instructable: ins))
}

/// The locked detail: version 1 rendered (the accepted one), steps 1 and 2 ticked, the
/// pending correction's changes tagged on the shown version, as `Store.detail` builds it.
@MainActor private func lockedSnapshot(_ review: ReviewState) -> DetailSnapshot {
    let item = reviewItem(reviewV1)
    var pending = false
    var firstView = false
    if case .pending(let shown, _, let baseline) = review {
        pending = true
        firstView = shown == nil && baseline == nil
    }
    let tagged = pending && !firstView
    return DetailSnapshot.build(
        item: item, detail: AskDetail(item: item, events: []), ticks: firstView ? [] : ["1", "2"], load: .loaded,
        reply: .idle, draft: nil, pendingChoice: nil, busy: false, previous: .end, next: .end, closedBy: nil,
        review: review, stamp: pending ? reviewStamps[1] : nil, chips: tagged ? reviewDiff.shownChips : [:],
        addedSinceShown: tagged ? reviewDiff.addedIDs.count : 0)
}

@MainActor private func reviewScene(_ name: String, _ snapshot: DetailSnapshot, page: ReviewPage? = nil,
                                    height: CGFloat? = 820) -> GalleryScene {
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id),
        status: readyStatus, reviewPages: page.map { [snapshot.id: $0] } ?? [:])
    return panelScene(name, model, height: height, rules: [], overrides: PanelGalleryOverrides(now: GalleryFixtures.now))
}

private let pending = ReviewState.pending(shown: reviewStamps[1], current: reviewStamps[3]!, baseline: 1)
private let firstView = ReviewState.pending(shown: nil, current: reviewStamps[3]!, baseline: nil)

/// Owner Key states in Settings › Queue.
@MainActor private func ownerKeyScene(_ name: String, state: OwnerKeyState, status: OwnerStatus?,
                                      canRequire: Bool = false,
                                      address: String = "https://mailbox.example:8790") -> GalleryScene {
    settingsScene(name, tab: .queue) {
        QueueTab(model: FixtureSettingsModel(
            settings: SettingsFixtures.snapshot(),
            draft: MailboxDraft(address: address, tokenFile: "~/.config/relay/mailbox-token"),
            ownerKeyState: state, ownerStatus: status, canRequireOwnerKey: canRequire))
    }
}

private let studioKey = OwnerKeyRow(id: "k2", label: "studio-mac", status: "approved", created: "2026-10-28T08:00:00+00:00",
                                    approvedAt: "2026-10-28T08:01:00+00:00")
private let thisKey = OwnerKeyRow(id: "k3", label: "example-mac", status: "approved", created: "2026-11-02T09:00:00+00:00",
                                  approvedAt: "2026-11-02T09:01:00+00:00")

@MainActor var reviewScenes: [GalleryScene] {
    [
        reviewScene("detail-locked", lockedSnapshot(pending)),
        reviewScene("detail-review", lockedSnapshot(pending), page: reviewPage(), height: 1180),
        reviewScene("detail-review-newer", lockedSnapshot(pending), page: reviewPage(latest: 4), height: 1180),
        reviewScene("detail-review-first-view", lockedSnapshot(firstView), page: firstViewPage(), height: 1180),
        reviewScene("detail-history-changed", lockedSnapshot(.historyChanged(.rolledBack))),
        ownerKeyScene("settings-owner-key-waiting", state: .waiting(id: "e1", code: "482913"),
                      status: OwnerStatus(required: false, keys: [studioKey])),
        ownerKeyScene("settings-owner-key-approved", state: .approved,
                      status: OwnerStatus(required: false, keys: [studioKey, thisKey], self_: OwnerSelf(id: "k3", status: "approved")),
                      canRequire: true),
        ownerKeyScene("settings-owner-key-not-used-here",
                      state: .notUsedHere(OwnerKeyFlow.notUsedHere(scheme: "https")),
                      status: OwnerStatus(required: false, keys: [studioKey, thisKey]),
                      address: "http://mailbox.example:8790"),
    ]
}
