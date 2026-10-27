import AppKit
import RelayCore
import WebKit

/// Hook's document viewer: one small window per file, titled with the file name, with
/// ⌘F (find), ⌘G / ⇧⌘G (next and previous match) and ⌘W (close). Opening a file that is
/// already open brings its window forward with the file read again.
@MainActor public final class DocumentViewer {
    public static let shared = DocumentViewer()

    private var windows: [String: DocumentWindowController] = [:]

    /// Shows `contents` (the bytes a click's check read from `file`) as `kind`; `file` only
    /// names the window. False when the bytes are too many for the viewer (the caller opens
    /// the file elsewhere).
    @discardableResult
    public func show(_ file: URL, contents: Data, kind: DocumentKind) -> Bool {
        let key = file.standardizedFileURL.path
        guard let page = Self.page(file, contents: contents, kind: kind) else { return false }
        let content = DocumentWebView(page: page, folder: file.deletingLastPathComponent())
        content.onOpenDocument = { [weak self] url in self?.openLinked(url) }
        if let existing = windows[key] {
            existing.replace(content)
        } else {
            let controller = DocumentWindowController(file: file, content: content)
            controller.onClose = { [weak self] in self?.windows[key] = nil }
            windows[key] = controller
        }
        windows[key]?.present()
        content.load()
        return true
    }

    /// The page for bytes already read; nil when there are more than `DocumentPage.maxBytes`.
    static func page(_ file: URL, contents: Data, kind: DocumentKind) -> String? {
        guard contents.count <= DocumentPage.maxBytes else { return nil }
        return DocumentPage.html(text: DocumentPage.text(contents), kind: kind, title: file.lastPathComponent,
                                 stylesheet: DS.Viewer.stylesheet())
    }

    /// A link in a page to another document in its folder: checked and read the way a file
    /// row's Open is (one detached task), then shown from those bytes.
    private func openLinked(_ url: URL) {
        let path = url.path(percentEncoded: false)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FileAccess.check(path, readingUpTo: { _ in DocumentPage.maxBytes })
            }.value
            guard case .document(let file) = result, let contents = file.contents,
                  let kind = DocumentKind(fileExtension: file.url.pathExtension),
                  self?.show(file.url, contents: contents, kind: kind) == true else { return NSSound.beep() }
        }
    }
}

/// The viewer window: the page, and a search field in the toolbar.
@MainActor final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private var content: DocumentWebView
    private let search = NSSearchToolbarItem(itemIdentifier: DocumentWindowController.searchID)
    var onClose: () -> Void = {}

    static let searchID = NSToolbarItem.Identifier("hook.viewer.search")

    init(file: URL, content: DocumentWebView) {
        self.content = content
        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: DS.Viewer.windowWidth, height: DS.Viewer.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = file.lastPathComponent
        window.representedURL = file
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: DS.Viewer.windowMinWidth, height: DS.Viewer.windowMinHeight)
        window.contentView = content.webView
        window.setFrameAutosaveName("HookDocumentViewer")
        super.init(window: window)
        window.delegate = self
        window.finder = self
        let toolbar = NSToolbar(identifier: "hook.viewer.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        search.searchField.placeholderString = "Find"
        search.searchField.sendsWholeSearchString = true
        search.searchField.target = self
        search.searchField.action = #selector(findFromField(_:))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A re-opened file: the new page in the same window.
    func replace(_ next: DocumentWebView) {
        content = next
        window?.contentView = next.webView
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(content.webView)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    // MARK: Find

    func beginFind() {
        search.beginSearchInteraction()
    }

    @objc private func findFromField(_ sender: NSSearchField) {
        find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
    }

    func find(backwards: Bool) {
        let text = search.searchField.stringValue
        guard !text.isEmpty else { return beginFind() }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        content.webView.find(text, configuration: configuration) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == Self.searchID ? search : nil
    }
}

/// Handles the viewer's keys itself: Hook has no File or Find menu.
final class DocumentWindow: NSWindow {
    weak var finder: DocumentWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "w" { performClose(nil); return true }
        if flags == .command, key == "f" { finder?.beginFind(); return true }
        if key == "g", flags == .command || flags == [.command, .shift] {
            finder?.find(backwards: flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
