import Foundation
import Testing
@testable import RelayCore

/// `viewer` in config.json: back-compatible, lenient, and saved as only what differs.
@Suite struct ViewerThemeTests {
    private func config(_ json: String) throws -> RelayConfig {
        try RelayConfig.decode(Data(json.utf8))
    }

    @Test func aConfigWithoutViewerReadsAsTheOriginalLook() throws {
        let theme = try config(#"{"source": "local"}"#).viewer
        #expect(theme == ViewerTheme())
        #expect(theme.preset == .system)
        #expect(theme.colors.isEmpty)
        #expect(theme.width == .full)
        #expect(theme.textSize == 0)
        #expect(theme.configValue.isEmpty)
    }

    @Test func everyKeyIsRead() throws {
        let theme = try config("""
            {"viewer": {"preset": "sepia", "colors": {"headings": "#7A2E0E", "links": "#18f"},
             "width": "narrow", "textSize": 2}}
            """).viewer
        #expect(theme.preset == .sepia)
        #expect(theme.colors == [.headings: "#7a2e0e", .links: "#1188ff"])
        #expect(theme.width == .narrow)
        #expect(theme.textSize == 2)
    }

    @Test func aBadValueTakesItsDefaultAndKeepsTheRest() throws {
        let theme = try config("""
            {"viewer": {"preset": "neon", "colors": {"headings": "red", "text": 12, "nope": "#000000",
             "links": "#123456"}, "width": 3, "textSize": 99}}
            """).viewer
        #expect(theme.preset == .system)
        #expect(theme.colors == [.links: "#123456"])
        #expect(theme.width == .full)
        #expect(theme.textSize == ViewerTheme.textSizeSteps.upperBound)
        // A viewer that isn't an object is no theme at all, and the rest of the config still reads.
        let other = try config(#"{"viewer": "sepia", "port": 4000}"#)
        #expect(other.viewer == ViewerTheme())
        #expect(other.port == 4000)
    }

    @Test func theSavedValueHoldsOnlyWhatDiffers() throws {
        var theme = ViewerTheme(preset: .night)
        #expect(theme.configValue as? [String: String] == ["preset": "night"])
        theme = theme.setting(.links, to: "#ABCDEF")
        theme.width = .wide
        theme.textSize = -1
        let value = theme.configValue
        #expect(value["preset"] as? String == "night")
        #expect(value["colors"] as? [String: String] == ["links": "#abcdef"])
        #expect(value["width"] as? String == "wide")
        #expect(value["textSize"] as? Int == -1)
        // What is saved reads back as the same theme.
        let data = try JSONSerialization.data(withJSONObject: ["viewer": value])
        #expect(try RelayConfig.decode(data).viewer == theme)
        // Back to the preset's colour.
        #expect(theme.setting(.links, to: nil).colors.isEmpty)
        #expect(theme.setting(.links, to: "blue").colors.isEmpty)
    }

    @Test func hexColours() {
        #expect(ViewerTheme.hex("#ABC") == "#aabbcc")
        #expect(ViewerTheme.hex(" #a1B2c3 ") == "#a1b2c3")
        for bad in ["abc", "#abcd", "#ggg", "", "#", "rgb(1,2,3)"] { #expect(ViewerTheme.hex(bad) == nil, "\(bad)") }
        #expect(ViewerTheme.isDark("#16171a"))
        #expect(!ViewerTheme.isDark("#f4ecd8"))
        #expect(!ViewerTheme.isDark("#ffffff"))
    }
}
