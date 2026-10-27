import RelayCore
import Testing
@testable import RelayUI

@Suite @MainActor struct HeaderComponentTests {
    @Test func refreshHelp() {
        #expect(ListHeaderBar.refreshHelp(updated: "10:42") == "Refresh (⌘R) · updated 10:42")
        #expect(ListHeaderBar.refreshHelp(updated: "") == "Refresh (⌘R)")
    }

    @Test func queueMenuValueAndItems() {
        #expect(QueueMenu.accessibilityValue(grouping: .project, filter: nil) == "Grouped by project, all projects")
        #expect(QueueMenu.accessibilityValue(grouping: .urgency, filter: "Acme") == "Grouped by urgency, showing Acme")
        #expect(QueueMenu.accessibilityValue(grouping: .project, filter: "A\nB") == "Grouped by project, showing A⟨U+000A⟩B")
        #expect(QueueMenu.accessibilityValue(grouping: .project, filter: "") == "Grouped by project, showing No project")
        #expect(QueueMenu.itemTitle(MenuProject(name: "Acme", open: 3)) == "Acme (3)")
        #expect(QueueMenu.itemTitle(MenuProject(name: "", open: 1)) == "No project (1)")
        #expect(QueueMenu.help == "Group and filter · ⌃⌘G switches grouping")
    }

    @Test func filterToken() {
        #expect(FilterToken.accessibilityText("Acme") == "Showing only Acme. Show all projects")
        #expect(FilterToken.accessibilityText("") == "Showing only No project. Show all projects")
    }

    @Test func hiddenAsks() {
        #expect(HiddenAsksButton.text(HiddenCount(total: 1, now: 0)) == "1 more in other projects")
        #expect(HiddenAsksButton.text(HiddenCount(total: 2, now: 1)) == "2 more in other projects, 1 now")
        #expect(HiddenAsksButton.accessibilityText(HiddenCount(total: 2, now: 1))
            == "2 more asks in other projects, 1 now. Show all projects")
        #expect(HiddenAsksButton.accessibilityText(HiddenCount(total: 1, now: 0))
            == "1 more ask in other projects. Show all projects")
    }

    @Test func detailHeader() {
        #expect(DetailHeaderBar.neighbourHelp(.ask("b"), previous: true) == "Previous ask (⌘↑)")
        #expect(DetailHeaderBar.neighbourHelp(.end, previous: false) == "Next ask (⌘↓)")
        #expect(DetailHeaderBar.neighbourHelp(.outsideFilter, previous: true) == "Not in the filtered queue")
        #expect(DetailHeaderBar.hideHelp == "Hide (⌘W)")
        #expect(DetailHeaderBar.metaText(project: "Acme", urgency: .now, age: "3 h ago") == "Acme · Now · 3 h ago")
        #expect(DetailHeaderBar.metaText(project: "", urgency: .unknown("x\ty"), age: "now") == "— · x⟨U+0009⟩y · now")
    }

    @Test func dockActionNames() {
        #expect(PanelHeaderActions.dockLeft == "Dock on the left edge")
        #expect(PanelHeaderActions.dockRight == "Dock on the right edge")
        #expect(PanelHeaderActions.dragHelp == "Drag to the left or right edge of any display to pin Hook there")
    }
}
