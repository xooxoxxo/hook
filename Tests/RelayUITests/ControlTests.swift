import AppKit
import SwiftUI
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

    /// Owner pick 2: a small outlined "?" in tertiary, never the stock filled HelpLink.
    @Test func helpButtonIsOutlinedCaptionTertiary() {
        #expect(DS.Symbol.helpOutline == "questionmark.circle")
        #expect(HelpButton.symbol == DS.Symbol.helpOutline)
        #expect(HelpButton.font == DS.Font.caption)
        // HierarchicalShapeStyle isn't Equatable; its description names the level.
        #expect(String(describing: HelpButton.foreground) == String(describing: DS.Color.tertiary))
        #expect(String(describing: HelpButton.foreground) != String(describing: HierarchicalShapeStyle.secondary))
    }

    @Test func helpButtonKeepsAccessibilityLabel() {
        #expect(HelpButton.accessibilityLabel(rowLabel: "Messages") == "Help: Messages")
    }

    /// The style's cap height is its text style's, so the glyph centres on that label's capitals.
    @Test func capHeightFollowsTheLabelStyle() {
        #expect(DS.Font.capHeight(.heading) == DS.Font.headingCapHeight)
        #expect(DS.Font.capHeight(.body) == NSFont.preferredFont(forTextStyle: .body).capHeight)
        #expect(DS.Font.capHeight(.caption) < DS.Font.capHeight(.body))
        #expect(EnvironmentValues().helpLabelStyle == .body)
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
