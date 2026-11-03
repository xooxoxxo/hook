import Foundation
@testable import RelayCore
import Testing
@testable import RelayUI

/// A crash with a symbolicated report, and one with none (a hang or a kill).
let crashWithReport = CrashSummary(
    report: IPSReport(exception: "EXC_BAD_ACCESS", signal: "SIGSEGV", termination: nil,
                      appFrames: [.init(symbol: "SettingsWindow.open(tab:)", offset: 212, imageOffset: 0x1a2b)]),
    hookVersion: "0.12.0", macOS: "15.6.0", cpu: "arm64", when: fixedNow.addingTimeInterval(-3600))
let crashWithoutReport = CrashSummary(report: nil, hookVersion: "0.12.0", macOS: "15.6.0", cpu: "arm64",
                                      when: fixedNow.addingTimeInterval(-3600))

/// What a @Sendable shell action was called with.
@MainActor final class SentValues<T> {
    var items: [T] = []
}

@Suite @MainActor struct CrashBarTests {
    @Test func theOfferAppearsAndClearsOnNotNow() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        var handled: [String] = []
        store.onCrashHandled = { handled.append($0) }
        #expect(store.crashOffer == nil)

        store.offerCrash(crashWithReport)
        #expect(store.crashOffer == CrashOffer(summary: crashWithReport))

        store.dismissCrash()
        #expect(store.crashOffer == nil)
        #expect(handled == [crashWithReport.signature])
        // Not Now twice records it once.
        store.dismissCrash()
        #expect(handled == [crashWithReport.signature])
    }

    /// A swap of the source keeps the bar: it is about the app, not the queue.
    @Test func theOfferOutlivesASourceSwap() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        store.offerCrash(crashWithoutReport)
        store.swap(to: nil, identity: SourceIdentity(key: SourceKey.none, mailbox: nil), pollSeconds: 60)
        #expect(store.crashOffer?.summary == crashWithoutReport)
    }

    @Test func captions() {
        #expect(CrashBar.title == "Hook quit unexpectedly")
        #expect(CrashBar.caption(CrashOffer(summary: crashWithReport)) == "Last run · report ready, nothing sent")
        #expect(CrashBar.caption(CrashOffer(summary: crashWithoutReport)) == "Last run · no crash report, log only")
        #expect(CrashBar.accessibilityText(CrashOffer(summary: crashWithReport))
            == "Hook quit unexpectedly. Last run · report ready, nothing sent")
    }

    @Test func switchingAProfileSavesThroughTheShell() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        let saved = SentValues<SourceKind>()
        store.shell.switchSource = { saved.items.append($0) }
        let config = RelayConfig(source: .local, mailboxURL: "https://pond.example.com", tokenFile: "~/t")
        store.setProfiles(ProfileMenu.make(config: config))
        #expect(store.profiles.label == "This Mac")

        store.switchProfile(.local)   // already shown: nothing to save
        store.switchProfile(.mailbox)
        #expect(saved.items == [.mailbox])

        store.setProfiles(ProfileMenu.make(config: config, readOnly: true))
        store.switchProfile(.mailbox)
        #expect(saved.items == [.mailbox])
    }

    @Test func theStatusShowsUpdating() {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = Store(defaults: defaults.defaults)
        store.setUpdating(true)
        #expect(store.status.text == "Updating…")
        store.setUpdating(false)
        #expect(store.status.text == "Not set up")
    }

    /// The header drops the count; VoiceOver still hears it.
    @Test func theHeaderTitleIsQueueAndItsLabelCounts() {
        #expect(ListHeaderBar.accessibilityTitle(waiting: 5) == "Queue, 5 waiting")
        #expect(ListHeaderBar.accessibilityTitle(waiting: 0) == "Queue, nothing waiting")
    }

    @Test func statusBarSentences() {
        let status = PanelStatus.make(StatusInputs(sourceKey: "mailbox:m#p", reachable: true, loadedOnce: true))
        #expect(StatusBarText.accessibilityText(status) == "Status: Pond, ready. Shows details")
        #expect(StatusBarText.profileLabel("Personal") == "Profile Personal")
    }
}
