import Testing
@testable import RelayUI

@Suite @MainActor struct StateComponentTests {
    @Test func titles() {
        #expect(StateView.title(.loading(source: "Mailbox", stillTrying: false)) == "Loading asks")
        #expect(StateView.title(.empty(updated: "10:42")) == "Nothing waiting")
        #expect(StateView.title(.emptyFiltered(project: "Acme", updated: "10:42")) == "Nothing waiting in Acme")
        #expect(StateView.title(.emptyFiltered(project: "A\nB", updated: "10:42")) == "Nothing waiting in A⟨U+000A⟩B")
        #expect(StateView.title(.offline(title: "Can't reach the mailbox", reason: "timed out")) == "Can't reach the mailbox")
        #expect(StateView.title(.notSetUp) == "No queue set up")
        #expect(StateView.title(.notFound(canShowClosed: true)) == "This ask is no longer open")
    }

    @Test func descriptions() {
        #expect(StateView.description(.loading(source: "Mailbox", stillTrying: false)) == "From Mailbox")
        #expect(StateView.description(.loading(source: "This Mac", stillTrying: false)) == "From This Mac")
        #expect(StateView.description(.loading(source: "Mailbox", stillTrying: true)) == "Still trying…")
        #expect(StateView.description(.empty(updated: "10:42")) == "Updated 10:42")
        #expect(StateView.description(.offline(title: "x", reason: "timed out")) == "timed out")
        #expect(StateView.description(.notSetUp) == "Choose where asks come from.")
        #expect(StateView.description(.notFound(canShowClosed: false)) == "It was closed or removed.")
    }

    @Test func actionTitles() {
        #expect(StateView.actionTitles(.loading(source: "This Mac", stillTrying: false)) == [])
        #expect(StateView.actionTitles(.loading(source: "This Mac", stillTrying: true)) == ["Queue Settings…"])
        #expect(StateView.actionTitles(.empty(updated: "10:42")) == [])
        #expect(StateView.actionTitles(.emptyFiltered(project: "Acme", updated: "10:42")) == ["Show All Projects"])
        #expect(StateView.actionTitles(.offline(title: "x", reason: "y")) == ["Try Again", "Queue Settings…"])
        #expect(StateView.actionTitles(.notSetUp) == ["Set Up…"])
        #expect(StateView.actionTitles(.notFound(canShowClosed: true)) == ["Back to Queue", "Show Closed Ask"])
        #expect(StateView.actionTitles(.notFound(canShowClosed: false)) == ["Back to Queue"])
    }

    @Test func settingsHelpers() {
        #expect(ShortcutField.clearLabel == "Turn the shortcut off")
        #expect(MailboxFields.addressPrompt == "https://mailbox.example:8790")
        #expect(MailboxFields.tokenHelp == "Hook reads this file only to talk to the mailbox and never shows what it holds.")
    }
}
