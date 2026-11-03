import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// The Messages section (pick 4 A): a side note to the posting session, from a Pond 1.2.0 or
/// later only. A message never answers, closes or changes anything.
@Suite @MainActor struct StoreMessageTests {
    private let pond12 = PondVersion.semver(SemVer(major: 1, minor: 2, patch: 0))
    private let pond11 = PondVersion.semver(SemVer(major: 1, minor: 1, patch: 0))

    private func started(_ defaults: TestDefaults, item ask: WireItem = item("a", created: stamp(minutesAgo: 5), steps: 2),
                         identity: SourceIdentity = mailboxIdentity) async -> (Store, FakeQueueSource) {
        let store = Store(defaults: defaults.defaults, now: { fixedNow })
        let fake = FakeQueueSource(items: [ask])
        await start(store, fake, identity: identity)
        store.setPond(pond12)
        return (store, fake)
    }

    @Test func aMessageSendsTheDraftClearsAndAppearsAfterTheReload() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults)
        let text = "Use the staging key first.\nThen prod."
        store.messageDrafts["a"] = text
        #expect(await store.sendMessage("a", text: text))
        #expect(await fake.messages["a"] == [text])
        #expect(store.messageDrafts["a"] == nil)
        #expect(store.detail("a")?.messages.map(\.text) == [text])
        #expect(store.detail("a")?.message == .idle)
    }

    @Test func aMessageNeverMovesTheReplyOrAnswers() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let ask = item("a", created: stamp(minutesAgo: 5), steps: 2, reply: ReplySpec(prompt: "Which region?"))
        let (store, fake) = await started(defaults, item: ask)
        store.drafts["a"] = "half a reply"
        let before = store.detail("a")
        #expect(await store.sendMessage("a", text: "Checking the docs first"))
        let after = store.detail("a")
        #expect(after?.reply == before?.reply)
        #expect(after?.replies == [])
        #expect(after?.primary == before?.primary)
        #expect(after?.model?.ownerReplies == [])
        #expect(store.drafts["a"] == "half a reply")
        #expect(after?.row.closed == nil)
        #expect(await fake.count("reply") == 0)
        #expect(await fake.count("resolve") == 0)
    }

    @Test func theSectionIsHiddenBelowPond120AndOnThisMac() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults)
        #expect(store.detail("a")?.canMessage == true)
        store.setPond(pond11)
        #expect(store.detail("a")?.canMessage == false)
        #expect(!(await store.sendMessage("a", text: "hello")))
        #expect(await fake.count("message") == 0)

        let local = TestDefaults()
        defer { local.drop() }
        let (mac, _) = await started(local, identity: localIdentity)
        #expect(mac.detail("a")?.canMessage == false)
    }

    @Test func aRefusalKeepsTheDraftAndSaysWhy() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults)
        store.messageDrafts["a"] = "the token is ghp_example"
        await fake.failNext(QueueError.rejected(status: 400, error: "invalid message", details: ["text: secret-like value"]),
                            on: "message")
        #expect(!(await store.sendMessage("a", text: "the token is ghp_example")))
        #expect(store.detail("a")?.message == .failed(MessageText.secretRefused))
        #expect(store.messageDrafts["a"] == "the token is ghp_example")
        store.messageDrafts["a"] = "the token is in the vault"
        #expect(store.detail("a")?.message == .idle)
    }

    @Test func aClosedAskTakesNoMessage() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults)
        await fake.setItems([])
        await fake.setClosed([closed(item("a", created: stamp(minutesAgo: 5), steps: 2))])
        await store.refresh()
        #expect(!(await store.sendMessage("a", text: "One more thing")))
        #expect(await fake.count("message") == 0)
    }

    @Test func commandReturnInTheFieldSendsTheDraftAndCommandLFocusesIt() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake) = await started(defaults)
        store.open("a")
        #expect(store.keyContext(textFieldFocused: false, popoverOpen: false, closedHeaderFocused: false).canMessage)
        store.perform(.focusMessage)
        #expect(store.messageFocus == "a")
        let typing = store.keyContext(textFieldFocused: true, popoverOpen: false, closedHeaderFocused: false)
        #expect(typing.messageFieldFocused)
        #expect(KeyMap.command(for: .cmdReturn, in: typing) == .sendMessage)
        store.messageDrafts["a"] = "Use the staging key"
        store.perform(.sendMessage)
        #expect(await eventually { await fake.messages["a"] == ["Use the staging key"] })
        #expect(await eventually { store.messageDrafts["a"] == nil })
        #expect(await fake.count("resolve") == 0)
    }

    @Test func messageSessionOpensTheAskAndFocusesTheField() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _) = await started(defaults)
        store.messageSession("a")
        #expect(store.navigation.selectedID == "a")
        #expect(store.messageFocus == "a")
    }
}
