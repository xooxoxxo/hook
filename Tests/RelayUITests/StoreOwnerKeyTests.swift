import Foundation
import RelayCore
import Testing
@testable import RelayUI

private let plain = [item("a", created: stamp(minutesAgo: 10))]

@Suite @MainActor struct StoreOwnerKeyTests {
    @Test func aRefusedKeyOnAReplyPostsTheNoticeAndTellsTheApp() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        var refused = 0
        store.onOwnerKeyRefused = { refused += 1 }
        let fake = FakeQueueSource(items: plain)
        await start(store, fake)
        await fake.failNext(QueueError.ownerKeyRefused, on: "reply")
        store.drafts["a"] = "C07QX2"
        #expect(!(await store.sendReply("a")))
        #expect(store.notice == .ownerKeyRefused)
        #expect(refused == 1)
    }

    @Test func aRefusedKeyOnReopenReplacesTheReopenNotice() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        var refused = 0
        store.onOwnerKeyRefused = { refused += 1 }
        let fake = FakeQueueSource(items: plain)
        await start(store, fake)
        await fake.failNext(QueueError.ownerKeyRefused, on: "reopen")
        await store.reopen("a")
        #expect(store.notice == .ownerKeyRefused)
        #expect(refused == 1)
        // Any other failure keeps its own Notice.
        await fake.failNext(QueueError.unreachable("offline"), on: "reopen")
        await store.reopen("a")
        if case .reopenFailed? = store.notice {} else { Issue.record("expected reopenFailed, got \(String(describing: store.notice))") }
        #expect(refused == 1)
    }

    @Test func theNoticeReadsAsAnErrorWithoutAButton() {
        let notice = PanelNotice.ownerKeyRefused
        #expect(notice.text == "The Pond no longer accepts this Mac's owner key. Set it up again in Settings › Queue.")
        #expect(notice.kind == .error)
        #expect(notice.actionTitle == nil)
        #expect(notice.showsOnQueue)
    }
}
