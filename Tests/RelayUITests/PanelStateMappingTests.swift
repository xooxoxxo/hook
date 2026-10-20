import Testing
@testable import RelayCore
@testable import RelayUI

@Suite struct PanelStateMappingTests {
    private func kind(_ content: PanelContent, source: String = "Mailbox") -> StateKind? {
        PanelStateMapping.kind(content, sourceName: source, updated: "09:40")
    }

    @Test func theListHasNoStateView() {
        #expect(kind(.list) == nil)
    }

    @Test func loadingNamesTheSourceAndLaterKeepsTrying() {
        #expect(kind(.loading(stillTrying: false)) == .loading(source: "Mailbox", stillTrying: false))
        #expect(kind(.loading(stillTrying: true), source: "This Mac") == .loading(source: "This Mac", stillTrying: true))
    }

    @Test func emptyStatesCarryTheUpdatedTime() {
        #expect(kind(.empty) == .empty(updated: "09:40"))
        #expect(kind(.emptyFiltered(project: "Atlas")) == .emptyFiltered(project: "Atlas", updated: "09:40"))
    }

    /// A filtered empty list is never the bare "Nothing waiting".
    @Test func filteredEmptyIsNeverTheBareEmpty() {
        #expect(kind(.emptyFiltered(project: "Atlas")) != .empty(updated: "09:40"))
    }

    @Test func offlineTitlesPerSourceAndASanitizedReason() {
        #expect(kind(.offline(local: false, reason: "timed out")) == .offline(title: "Can't reach the mailbox", reason: "timed out"))
        #expect(kind(.offline(local: true, reason: "Port 47823 is in use by another app"))
                == .offline(title: "This Mac isn't ready", reason: "Port 47823 is in use by another app"))
        #expect(kind(.offline(local: false, reason: "line one\nline two"))
                == .offline(title: "Can't reach the mailbox", reason: "line one⟨U+000A⟩line two"))
    }

    @Test func notSetUp() {
        #expect(kind(.notSetUp) == .notSetUp)
    }

    /// The not-set-up panel never shows one string twice; the StateView title and the
    /// status bar text differ.
    @Test func notSetUpTitleAndStatusDiffer() {
        let status = PanelStatus.make(StatusInputs(sourceKey: SourceKey.none, reachable: false, loadedOnce: false))
        #expect(StateView.title(.notSetUp) != status.text)
    }
}
