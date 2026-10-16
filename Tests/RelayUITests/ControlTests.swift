import Testing
@testable import RelayUI

@Suite @MainActor struct ControlTests {
    @Test func iconButtonHelpFallsBackToTheLabel() {
        #expect(IconButton.helpText(label: "Refresh", help: "Refresh (⌘R)") == "Refresh (⌘R)")
        #expect(IconButton.helpText(label: "Dismiss", help: nil) == "Dismiss")
    }

    @Test func helpButtonNamesItsRow() {
        #expect(HelpButton.accessibilityLabel(rowLabel: "Presence") == "Help: Presence")
    }

    @Test func disclosureValue() {
        #expect(TrailingDisclosureStyle.value(expanded: true) == "Expanded")
        #expect(TrailingDisclosureStyle.value(expanded: false) == "Collapsed")
    }
}
