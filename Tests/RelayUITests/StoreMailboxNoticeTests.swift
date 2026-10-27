import Foundation
import RelayCore
import Testing
@testable import RelayUI

@MainActor private final class Calls {
    var updates = 0
    var checks = 0
    var urls: [URL] = []
}

@MainActor private func store(_ calls: Calls) -> (Store, TestDefaults) {
    let defaults = TestDefaults()
    let store = Store(defaults: defaults.defaults)
    store.shell = PanelShellActions(hide: {}, setUp: {}, quit: {}, dock: { _ in }, openSettings: { _ in },
                                    copy: { _ in }, openURL: { calls.urls.append($0) })
    store.shell.updateMailbox = { calls.updates += 1 }
    store.shell.checkForUpdates = { calls.checks += 1 }
    return (store, defaults)
}

@Suite @MainActor struct StoreMailboxNoticeTests {
    @Test func howToUpdateOpensTheGuideAndKeepsTheNotice() {
        let calls = Calls()
        let (store, defaults) = store(calls)
        defer { defaults.drop() }
        store.post(.mailboxOlder(missing: [.blocking]))
        store.performNoticeSecondaryAction()
        #expect(calls.urls == [MailboxProtocol.updateDocsURL])
        #expect(store.notice == .mailboxOlder(missing: [.blocking]))
    }

    @Test func updateMailboxRunsTheUpdateAndClearsTheNotice() async {
        let calls = Calls()
        let (store, defaults) = store(calls)
        defer { defaults.drop() }
        store.post(.mailboxOlder(missing: [.blocking]))
        await store.performNoticeAction()
        #expect(calls.updates == 1)
        #expect(store.notice == nil)
    }

    @Test func newerChecksForHookUpdates() async {
        let calls = Calls()
        let (store, defaults) = store(calls)
        defer { defaults.drop() }
        store.post(.mailboxNewer)
        await store.performNoticeAction()
        #expect(calls.checks == 1)
        store.post(.settingsReloaded)
        store.performNoticeSecondaryAction()   // no second button: nothing happens
        #expect(calls.urls.isEmpty)
    }
}
