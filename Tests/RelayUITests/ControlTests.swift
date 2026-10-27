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

@Suite @MainActor struct SupportButtonTests {
    /// The setup window's last page shows Support Hook for the shipped link, and only for https.
    @Test func showsForAValidHTTPSLink() {
        #expect(WelcomeView<FixtureSettingsModel>.showsSupport())
        #expect(WelcomeView<FixtureSettingsModel>.showsSupport("https://ko-fi.com/xo-vision"))
        #expect(!WelcomeView<FixtureSettingsModel>.showsSupport(""))
        #expect(!WelcomeView<FixtureSettingsModel>.showsSupport("http://ko-fi.com/xo-vision"))
        #expect(!WelcomeView<FixtureSettingsModel>.showsSupport("ko-fi.com/xo-vision"))
    }
}
