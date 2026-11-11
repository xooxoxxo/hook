import AppKit
import Foundation
import RelayCore
import Testing
import WebKit
@testable import RelayUI
@testable import RelayUIMac

/// The viewer page in a real (offscreen) window: it follows the window's width, and a
/// table keeps whole words in its cells.
@Suite(.serialized) @MainActor struct ViewerLayoutTests {
    static let tableMarkdown = """
    # Plan

    | Step | Owner | What happens | Notes |
    | --- | --- | --- | --- |
    | Freeze | Release | The build is frozen and tagged for the beta channel | Nothing merges after this |
    | Beta | Everyone | The public beta goes out to every tester on the list | Watch the crash reports |
    """

    /// Loads `markdown` into a window of `width`, waits for the page, and returns the web view.
    func load(_ markdown: String, width: CGFloat, stylesheet: String) async throws -> (NSWindow, DocumentWebView) {
        let page = DocumentPage.html(text: markdown, kind: .markdown, title: "t.md", stylesheet: stylesheet)
        let content = DocumentWebView(page: page, folder: nil)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content.webView
        var loaded = false
        content.onLoaded = { loaded = true }
        content.load()
        // The first load starts WebKit's processes, which takes over 10 s on a cold CI runner.
        let deadline = Date().addingTimeInterval(30)
        while !loaded, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(loaded)
        try await Task.sleep(for: .milliseconds(200))
        return (window, content)
    }

    func number(_ view: WKWebView, _ script: String) async throws -> Double {
        let value = try await view.callAsyncJavaScript(
            "return \(script);", arguments: [:], in: nil, contentWorld: DocumentWebView.world)
        return try #require((value as? NSNumber)?.doubleValue)
    }

    func resize(_ window: NSWindow, width: CGFloat) async throws {
        window.setContentSize(NSSize(width: width, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func thePageFollowsTheWindowWidth() async throws {
        let (window, content) = try await load(Self.tableMarkdown, width: 720, stylesheet: DS.Viewer.stylesheet())
        let first = try await number(content.webView, "document.documentElement.clientWidth")
        let firstMain = try await number(content.webView, "document.getElementById('hook-doc').clientWidth")
        try await resize(window, width: 1300)
        let wider = try await number(content.webView, "document.documentElement.clientWidth")
        let widerMain = try await number(content.webView, "document.getElementById('hook-doc').clientWidth")
        #expect(abs(first - 720) <= 1)
        #expect(abs(wider - 1300) <= 1)
        // Full width (the default): the column is the window less the page inset.
        #expect(abs(firstMain - (720 - 2 * DS.Viewer.pageH)) <= 1)
        #expect(abs(widerMain - (1300 - 2 * DS.Viewer.pageH)) <= 1)
        window.close()
    }

    @Test func aNarrowColumnStopsAtItsMeasure() async throws {
        var theme = ViewerTheme()
        theme.width = .narrow
        let (window, content) = try await load(Self.tableMarkdown, width: 1300,
                                               stylesheet: DS.Viewer.stylesheet(theme: theme))
        let main = try await number(content.webView, "document.getElementById('hook-doc').clientWidth")
        #expect(abs(main - DS.Viewer.measure(.narrow)!) <= 1)
        window.close()
    }

    /// A theme change reaches an open page in place: the heading takes the new colour.
    @Test func aNewThemeRestylesTheOpenPage() async throws {
        let (window, content) = try await load(Self.tableMarkdown, width: 720, stylesheet: DS.Viewer.stylesheet())
        content.restyle(DS.Viewer.stylesheet(theme: ViewerTheme(colors: [.headings: "#ff0000"])))
        try await Task.sleep(for: .milliseconds(200))
        let red = try await number(content.webView, """
            getComputedStyle(document.querySelector('h1')).color === 'rgb(255, 0, 0)' ? 1 : 0
            """)
        #expect(red == 1)
        window.close()
    }

    /// No cell breaks a word: each cell is at least as wide as its longest word.
    @Test func tableCellsKeepWholeWords() async throws {
        let (window, content) = try await load(Self.tableMarkdown, width: DS.Viewer.windowMinWidth,
                                               stylesheet: DS.Viewer.stylesheet())
        let broken = try await number(content.webView, """
            Array.from(document.querySelectorAll('td, th')).filter(function (cell) {
              var range = document.createRange(); range.selectNodeContents(cell);
              var words = cell.textContent.trim().split(/\\s+/);
              var lines = range.getClientRects().length;
              return lines > words.length;
            }).length
            """)
        #expect(broken == 0)
        // A table wider than the window scrolls inside itself; the page doesn't.
        let pageScroll = try await number(content.webView,
                                          "document.documentElement.scrollWidth - document.documentElement.clientWidth")
        #expect(pageScroll <= 1)
        window.close()
    }
}
