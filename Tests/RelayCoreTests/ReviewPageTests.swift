import Foundation
import RelayCore
import Testing

/// The inline review's page (`ReviewPage`) and the lock bar (`ReviewLockBar`), built from the
/// real diff and Look-closer models.
@Suite struct ReviewPageTests {
    private let v1 = Instructable(
        v: 1, title: "Rotate the key", urgency: "today",
        steps: [
            Step(action: "Make a folder", code: "mkdir -p ~/keys", id: "s1"),
            Step(action: "Upload the key", code: "curl -fsS https://deploy.example.com/keys", id: "s2"),
            Step(action: "Restart the runner", code: "kestrel restart", id: "s3"),
            Step(action: "Tidy up", code: "rm old.key", id: "s4"),
        ],
        from: Origin(session: "7f3a2c1e-5b6d-4e8f", host: "example-mac", cwd: "~/src/kestrel"))

    private var v3: Instructable {
        var ins = v1
        ins.steps[1].code = "curl -fsS https://deploy.example.net/keys"
        ins.steps[2] = Step(action: "Restart both runners", code: "sudo kestrel restart --all", id: "s3")
        ins.steps.remove(at: 3)
        ins.steps.append(Step(action: "Check the runner", code: "kestrel status", id: "r3-1"))
        return ins
    }

    private let one = RevisionStamp(rev: 1, hash: String(repeating: "a", count: 64))
    private let three = RevisionStamp(rev: 3, hash: String(repeating: "c", count: 64))

    private func page(latest: RevisionStamp? = nil, baseline: Instructable? = nil, reasons: [(rev: Int, reason: String)]? = nil)
        -> ReviewPage {
        let diff = RevisionDiff.make(baseline: baseline, firstRevision: v1, current: v3,
                                     reasons: reasons ?? [(2, "Needs root."), (3, "Moved to .net.")])
        return ReviewPage.make(diff: diff, flags: LookCloser.flags(old: baseline, new: v3, cwd: "~/src/kestrel"),
                               body: v3, target: three, latest: latest ?? three,
                               baselineRev: baseline == nil ? nil : 1, time: { ["2": "10:31", "3": "10:42"]["\($0)"] ?? "" })
    }

    @Test func everyStepInOrderThenTheRemovedOnes() {
        let p = page(baseline: v1)
        #expect(p.steps.map(\.id) == ["s1", "s2", "s3", "r3-1", "removed:s4"])
        #expect(p.steps.map(\.change) == [.same, .changed, .changed, .added, .removed])
        #expect(p.steps.map(\.tag) == [nil, "Changed", "Changed", "New", "Removed"])
        #expect(p.steps.map(\.label) == ["1", "2", "3", "4", "4"])
        #expect(p.steps[0].fields.isEmpty)
        #expect(p.steps.map(\.dimmed) == [true, false, false, false, false])
        #expect(p.stepsSummary == "2 changed · 1 added · 1 removed")
    }

    @Test func aChangedStepShowsItsOldTextAndOnlyTheChangedWords() {
        let p = page(baseline: v1)
        let restart = p.steps[2]
        #expect(restart.action == "Restart both runners")
        #expect(restart.was == "Restart the runner")
        #expect(restart.fields.count == 1)
        #expect(restart.fields[0].label == nil)
        #expect(restart.fields[0].hasOld && restart.fields[0].hasNew)
        #expect(restart.fields[0].tokens.contains(.added("sudo ")))
        let added = p.steps[3]
        #expect(added.fields.allSatisfy { !$0.hasOld && $0.hasNew })
    }

    @Test func flagsSitUnderTheStepTheyWereFoundIn() {
        let p = page(baseline: v1)
        #expect(p.steps[1].flags.map(\.title) == ["New host deploy.example.net · not in version 1"])
        #expect(p.steps[1].flags.map(\.place) == ["Step 2"])
        #expect(p.steps[2].flags.map(\.title) == ["Runs as root: sudo"])
        #expect(p.flagCount == 2)
        #expect(p.barTitle == "2 flags to look closer at")
    }

    @Test func noFlagNeverReadsSafe() {
        var quiet = v1
        quiet.steps[0].expect = "Nothing printed"
        let diff = RevisionDiff.make(baseline: v1, firstRevision: v1, current: quiet, reasons: [])
        let p = ReviewPage.make(diff: diff, flags: LookCloser.flags(old: v1, new: quiet, cwd: nil), body: quiet,
                                target: three, latest: three, baselineRev: 1, time: { _ in "" })
        #expect(p.flagCount == 0)
        #expect(p.barTitle == "No flags")
        #expect(p.barDetail == LookCloser.incomplete)
        #expect(!p.needsPresence)
        #expect(p.primaryTitle == "Use Version 3")
    }

    @Test func aCommandChangeNeedsPresence() {
        #expect(page(baseline: v1).needsPresence)
    }

    @Test func aNewerVersionTurnsUseIntoShow() {
        let p = page(latest: RevisionStamp(rev: 4, hash: String(repeating: "d", count: 64)), baseline: v1)
        #expect(p.isStale)
        #expect(p.primaryTitle == "Show Version 4")
        #expect(p.heading == "Reviewing version 3 of 4 · 10:42")
        #expect(p.barTitle == "Version 4 arrived during your review")
    }

    @Test func reasonsAreQuotedWithHiddenCharactersRevealed() {
        let p = page(baseline: v1, reasons: [(2, "Fix\u{202E}it")])
        #expect(p.reasons.map(\.text) == ["The session says: Fix⟨U+202E⟩it"])
        #expect(p.reasons.map(\.heading) == ["Version 2 · 10:31"])
        #expect(p.attribution.hasPrefix("Posted by session 7f3a2c1e on example-mac."))
    }

    @Test func aFirstViewShowsEverythingUntagged() {
        let p = page()
        #expect(p.isFirstView)
        #expect(p.steps.map(\.tag).allSatisfy { $0 == nil })
        #expect(p.steps.count == 4)
        #expect(p.steps.allSatisfy { !$0.fields.isEmpty })
        #expect(p.since.hasPrefix(ReviewText.firstViewHeading))
        #expect(p.stepsSummary == "4 steps")
    }

    /// A first view keeps every row `.same`, yet none is dimmed: the commands and the flags
    /// under them are what the owner reads before Use Version 3.
    @Test func aFirstViewDimsNothing() {
        let p = page()
        #expect(p.isFirstView)
        #expect(p.steps.allSatisfy { $0.change == .same })
        #expect((p.steps + p.others).allSatisfy { !$0.dimmed })
        #expect(p.steps.contains { !$0.flags.isEmpty })
        // An unchanged row is dimmed only with nothing under it.
        let flags = p.steps.first { !$0.flags.isEmpty }?.flags ?? []
        #expect(ReviewPage.dims(.same, fields: [], flags: [], first: false))
        #expect(!ReviewPage.dims(.same, fields: [], flags: flags, first: false))
        #expect(!ReviewPage.dims(.same, fields: p.steps[0].fields, flags: [], first: false))
        #expect(!ReviewPage.dims(.same, fields: [], flags: [], first: true))
        #expect(!ReviewPage.dims(.changed, fields: [], flags: [], first: false))
    }

    @Test func shownChipsTagTheVersionStillShown() {
        let diff = RevisionDiff.make(baseline: v1, firstRevision: v1, current: v3, reasons: [])
        #expect(diff.shownChips == ["2": .changed, "3": .changed, "4": .removed])
        let first = RevisionDiff.make(baseline: nil, firstRevision: v1, current: v3, reasons: [])
        #expect(first.shownChips.isEmpty)
    }

    @Test func theLockBarSaysWhyAndOffersTheWayOut() {
        let pending = ReviewLockBar.make(.pending(shown: one, current: three, baseline: 1))
        #expect(pending?.tone == .correction)
        #expect(pending?.title == "Corrected after you saw it")
        #expect(pending?.detail.hasPrefix("Version 3 of 3 · 2 corrections.") == true)
        #expect(pending?.action == "Show Changes")
        let never = ReviewLockBar.make(.pending(shown: nil, current: three, baseline: nil))
        #expect(never?.title == "Corrected before this Mac showed it")
        let history = ReviewLockBar.make(.historyChanged(.rolledBack))
        #expect(history?.tone == .history)
        #expect(history?.action == "Trust the Pond's History Again…")
        #expect(ReviewLockBar.make(.legacy) == nil)
        #expect(ReviewLockBar.make(.current(three)) == nil)
    }
}
