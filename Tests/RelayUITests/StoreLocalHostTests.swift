import Combine
import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// The host name is cached on the Store and passed to the menus; rows never look it up.
@Suite @MainActor struct StoreLocalHostTests {
    @Test func theHostNameIsSetOnceAndPublishedOnlyOnChange() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        #expect(store.localHost == nil)
        var published = 0
        let watch = store.$localHost.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        store.setLocalHost("build-mac")
        store.setLocalHost("build-mac")
        #expect(store.localHost == "build-mac")
        #expect(published == 1)
        store.setLocalHost("renamed-mac")
        #expect(published == 2)
    }

    /// The cached name decides Resume Session in the menus.
    @Test func theMenusUseTheCachedName() throws {
        let origin = try #require(AskOrigin(from: Origin(session: "1b2c3d4e-0000-4000-8000-000000000001",
                                                         host: "build-mac", cwd: "/work/acme")))
        var row = AskRowModel(id: "a", title: "T", project: "Acme", urgency: .now, created: "c", summary: .reply)
        row.origin = origin
        let here = QueueContextMenu.resumeEntries(for: row, localHost: "build-mac")
        #expect(here.first == .item(title: QueueContextMenu.resumeTitle, command: .resume, shortcut: nil))
        let unknown = QueueContextMenu.resumeEntries(for: row, localHost: nil)
        #expect(unknown.first == .disabled(title: QueueContextMenu.resumeTitle, reason: "Session is on build-mac"))
    }
}
