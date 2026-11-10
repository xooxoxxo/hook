import AppKit
import Foundation
import RelayCore
import Testing
@testable import RelayUI

/// The stylesheet a theme makes, the in-place stylesheet swap, and the Dock icon's count.
@Suite @MainActor struct ViewerThemeStyleTests {
    @Test func theDefaultThemeIsTheSystemPaletteAtFullWidth() {
        let css = DS.Viewer.stylesheet()
        #expect(css == DS.Viewer.stylesheet(theme: ViewerTheme()))
        #expect(css.contains("color-scheme: light dark"))
        #expect(css.contains("prefers-color-scheme: dark"))
        #expect(css.contains("main { max-width: none;"))
        // Headings have their own variable, the text colour by default.
        #expect(css.contains("--heading: rgba("))
        #expect(css.contains("color: var(--heading)"))
        #expect(!css.contains(":root { --background:"))
    }

    @Test func theChosenColoursAreInTheStylesheet() {
        let theme = ViewerTheme(colors: [.background: "#101010", .text: "#eeeeee", .headings: "#ff8800",
                                         .links: "#00aaff", .code: "#222222", .rules: "#444444"])
        let css = DS.Viewer.stylesheet(theme: theme)
        for expected in ["--background: #101010;", "--text: #eeeeee;", "--heading: #ff8800;", "--link: #00aaff;",
                         "--code-fill: #222222;", "--separator: #444444;", "--quote-bar: #444444;"] {
            #expect(css.contains(expected), "\(expected)")
        }
        // A dark background of its own makes the page dark.
        #expect(css.contains("color-scheme: dark"))
        #expect(DS.Viewer.appearance(theme) == .darkAqua)
        // The owner's colours come after the dark block, so they win in both appearances.
        let dark = css.range(of: "prefers-color-scheme: dark")!, own = css.range(of: "--heading: #ff8800")!
        #expect(dark.lowerBound < own.lowerBound)
    }

    @Test func presetsSetEveryRoleAndTheTitleBar() {
        for preset in ViewerTheme.Preset.allCases where preset != .system {
            let colors = DS.Viewer.presetColors(preset) ?? [:]
            #expect(Set(colors.keys) == Set(ViewerTheme.Role.allCases), "\(preset)")
            let css = DS.Viewer.stylesheet(theme: ViewerTheme(preset: preset))
            for (_, hex) in colors { #expect(css.contains(hex), "\(preset) \(hex)") }
        }
        #expect(DS.Viewer.appearance(ViewerTheme(preset: .night)) == .darkAqua)
        #expect(DS.Viewer.appearance(ViewerTheme(preset: .sepia)) == .aqua)
        #expect(DS.Viewer.appearance(ViewerTheme(preset: .system)) == nil)
        // Without a heading colour of its own, a custom text colour colours headings too.
        let css = DS.Viewer.stylesheet(theme: ViewerTheme(colors: [.text: "#333333"]))
        #expect(css.contains("--heading: #333333;"))
    }

    @Test func readingWidthAndTextSize() {
        #expect(DS.Viewer.measure(.full) == nil)
        #expect(DS.Viewer.measure(.narrow) == 720)
        #expect((DS.Viewer.measure(.wide) ?? 0) > (DS.Viewer.measure(.narrow) ?? 0))
        let narrow = DS.Viewer.stylesheet(theme: ViewerTheme(width: .narrow))
        #expect(narrow.contains("main { max-width: 720px;"))
        #expect(narrow.contains(".front { max-width: 720px;"))
        let wide = DS.Viewer.stylesheet(theme: ViewerTheme(width: .wide))
        #expect(wide.contains("main { max-width: \(Int(DS.Viewer.measure(.wide)!))px;"))
        let bigger = DS.Viewer.stylesheet(theme: ViewerTheme(textSize: 3))
        #expect(bigger.contains("font: \(DS.Viewer.textSize + 3)px/"))
    }

    @Test func tablesKeepWholeWords() {
        let css = DS.Viewer.stylesheet()
        #expect(!css.contains("main { max-width: none; margin: 0 auto; overflow-wrap: anywhere"))
        #expect(css.contains("overflow-wrap: break-word"))
        #expect(css.contains("min-width: \(DS.Viewer.cellMinWidth)em"))
        #expect(css.contains("overflow-x: auto"))
    }

    @Test func theStylesheetIsSwappedInPlace() {
        let page = DocumentPage.html(text: "# a </style> b", kind: .markdown, title: "</style>.md",
                                     stylesheet: "body { color: red; }")
        let next = DocumentPage.replacingStylesheet(in: page, with: "body { color: blue; }")
        #expect(next.contains("<style id=\"\(DocumentPage.styleID)\">\nbody { color: blue; }\n</style>"))
        #expect(!next.contains("color: red"))
        #expect(next.replacingOccurrences(of: "blue", with: "red") == page)
    }

    @Test func aWindowMakesHookRegularUntilTheLastCloses() {
        let presence = AppPresence()
        var applied: [NSApplication.ActivationPolicy] = []
        presence.apply = { applied.append($0) }
        presence.isActive = { false }
        let a = NSWindow(), b = NSWindow()
        presence.track(a)
        presence.track(b)
        presence.track(a)
        #expect(applied == [.regular])
        #expect(presence.count == 2)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: a)
        #expect(applied == [.regular])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: b)
        #expect(applied == [.regular, .accessory])
        #expect(presence.count == 0)
    }

    /// While Hook is the active app, it waits to resign before it hides its Dock icon, and a
    /// window opened meanwhile keeps it regular.
    @Test func theLastCloseWaitsForHookToResignActive() {
        let presence = AppPresence()
        var applied: [NSApplication.ActivationPolicy] = []
        presence.apply = { applied.append($0) }
        presence.isActive = { true }
        let a = NSWindow()
        presence.track(a)
        presence.closed(ObjectIdentifier(a))
        #expect(applied == [.regular])
        presence.track(a)
        presence.resigned()
        #expect(applied == [.regular])
        presence.closed(ObjectIdentifier(a))
        presence.resigned()
        #expect(applied == [.regular, .accessory])
    }
}
