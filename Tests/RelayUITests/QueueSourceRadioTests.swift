import RelayCore
@testable import RelayUI
import Testing

struct QueueSourceRadioTests {
    @Test func aPollSecondsSaveKeepsAPickedMailbox() {
        let old = RelayConfig(source: .local)
        let new = RelayConfig(source: .local, pollSeconds: 30)
        #expect(QueueSourceRadio.afterConfigChange(current: .mailbox, old: old, new: new) == .mailbox)
    }

    @Test func aReloadWithTheSameSourceKeepsAPickedMailbox() {
        let config = RelayConfig(source: .local)
        #expect(QueueSourceRadio.afterConfigChange(current: .mailbox, old: config, new: config) == .mailbox)
        #expect(QueueSourceRadio.afterConfigChange(current: .mailbox, old: nil, new: nil) == .mailbox)
    }

    @Test func aChangedSavedSourceMovesTheRadio() {
        let local = RelayConfig(source: .local)
        let mailbox = RelayConfig(source: .mailbox, mailboxURL: "https://mailbox.example", tokenFile: "~/token")
        #expect(QueueSourceRadio.afterConfigChange(current: .local, old: local, new: mailbox) == .mailbox)
        #expect(QueueSourceRadio.afterConfigChange(current: .mailbox, old: mailbox, new: local) == .local)
    }

    @Test func aLegacyMailboxURLCountsAsMailbox() {
        #expect(QueueSourceRadio.saved(RelayConfig(mailboxURL: "https://mailbox.example")) == .mailbox)
        #expect(QueueSourceRadio.saved(nil) == .local)
    }

    /// A reinstalled app over a kept config: setup shows ("pending") and its source page
    /// starts from the saved Pond, so a returning user only confirms.
    @Test func setupOverAKeptConfigStartsFromIt() {
        let kept = RelayConfig(source: .mailbox, mailboxURL: "https://mailbox.example:8790",
                               tokenFile: "/home/tester/.config/relay/mailbox-token", context: "work",
                               onboarding: RelayConfig.onboardingPending)
        #expect(WelcomeFlow.showsAtLaunch(.loaded(kept)))
        #expect(QueueSourceRadio.saved(kept) == .mailbox)
        #expect(MailboxDraft(config: kept, home: "/home/tester")
            == MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/.config/relay/mailbox-token", context: "work"))
    }
}
