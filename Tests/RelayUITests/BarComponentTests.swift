import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let deadline = Date(timeIntervalSince1970: 1_000)

@Suite @MainActor struct BarComponentTests {
    @Test func undoText() {
        #expect(UndoBar.text(UndoInfo(verdict: .done, title: "Store the key", deadline: deadline, more: 0)) == "Done · Store the key")
        #expect(UndoBar.text(UndoInfo(verdict: .declined, title: "Store\nthe key", deadline: deadline, more: 2))
            == "Skipped · Store⟨U+000A⟩the key · +2 more")
    }

    @Test func undoSentence() {
        let undo = UndoInfo(verdict: .done, title: "Store the key", deadline: deadline, more: 0)
        #expect(UndoBar.accessibilityText(undo, secondsLeft: 8) == "Done: Store the key. Undo, 8 seconds left")
        #expect(UndoBar.accessibilityText(undo, secondsLeft: 1) == "Done: Store the key. Undo, 1 second left")
        #expect(UndoBar.accessibilityText(UndoInfo(verdict: .declined, title: "X", deadline: deadline, more: 1), secondsLeft: 3)
            == "Skipped: X. Undo, 3 seconds left")
        #expect(UndoBar.secondsLeft(until: deadline, now: deadline.addingTimeInterval(-7.2)) == 8)
        #expect(UndoBar.secondsLeft(until: deadline, now: deadline.addingTimeInterval(5)) == 0)
        #expect(UndoBar.announcement == "Done. Undo available for 10 seconds.")
    }

    @Test func statusSentence() {
        #expect(StatusBarText.accessibilityText("Mailbox · ready") == "Status: Mailbox · ready. Shows details")
    }

    @Test func actionBarHelp() {
        #expect(ActionBar.primaryHelp(.done) == "Done (⌘↩)")
        #expect(ActionBar.primaryHelp(.sendAndDone) == "Send and close (⌘↩)")
        #expect(ActionBar.skipHelp == "Skip (⌘⌫)")
        #expect(ActionBar.reopenHelp == "Reopen (⇧⌘R)")
    }

    @Test func noticeSymbols() {
        #expect(Notice.symbol(.error) == DS.Symbol.error)
        #expect(Notice.symbol(.info) == DS.Symbol.info)
    }
}
