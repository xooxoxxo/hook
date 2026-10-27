import AppKit
import RelayCore
import WebKit

/// The viewer's web view: one page Hook builds (`DocumentPage`), no network, no page script.
/// - Content JavaScript is off; marked, DOMPurify and viewer.js run as user scripts in
///   Hook's own content world, so a script in the document can't run even if it got through.
/// - A content rule list blocks every load that isn't `hook-doc:`, and the scheme handler
///   serves only the page and images inside the document's folder.
/// - A clicked web link opens in the default browser; a relative link to a Markdown or text
///   file in the folder opens in the viewer; anything else does nothing.
@MainActor public final class DocumentWebView: NSObject {
    public let webView: WKWebView
    private let handler: DocumentSchemeHandler
    /// Opens a local document a link in the page points to (in the viewer).
    var onOpenDocument: (URL) -> Void = { _ in }
    /// Called once the page has loaded (the gallery waits on it).
    public var onLoaded: () -> Void = {}

    public init(page: String, folder: URL?) {
        handler = DocumentSchemeHandler(page: Data(page.utf8), folder: folder)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: DocumentPage.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        let world = WKContentWorld.world(name: "hook-viewer")
        for source in DocumentPage.scripts() ?? [] {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        // A force-click preview would load the link in a page of its own, outside these rules.
        webView.allowsLinkPreview = false
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Compiles the rule list (once per launch), then loads the page.
    public func load() {
        Self.ruleList { [weak self] list in
            guard let self else { return }
            // Without the rule list the scheme handler and the CSP still fence the page in.
            if let list { self.webView.configuration.userContentController.add(list) }
            self.webView.load(URLRequest(url: DocumentPage.pageURL))
        }
    }

    /// Block every load, then let `hook-doc:` through.
    static let rules = """
    [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "^\(DocumentPage.scheme):"}, "action": {"type": "ignore-previous-rules"}}]
    """

    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []

    static func ruleList(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return done(compiled) }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "hook-viewer-no-network", encodedContentRuleList: rules) { list, _ in
            MainActor.assumeIsolated {
                compiled = list
                let callbacks = waiting
                waiting = []
                for callback in callbacks { callback(list) }
            }
        }
    }

    /// What a click on `url` in the page does.
    enum LinkAction: Equatable {
        case allow, browser(URL), document(URL), ignore
    }

    static func action(for url: URL?, isClick: Bool, folder: URL?) -> LinkAction {
        guard let url else { return .ignore }
        if url.scheme?.lowercased() == DocumentPage.scheme {
            // The page itself, or a jump to an anchor in it.
            if url.path(percentEncoded: false).isEmpty || url.path(percentEncoded: false) == "/" {
                return .allow
            }
            guard isClick, let folder, let target = DocumentPage.localFile(for: url, in: folder),
                  DocumentKind(fileExtension: target.pathExtension) != nil else { return .ignore }
            return .document(target)
        }
        if isClick, LinkDisplay.isWeb(url.absoluteString) { return .browser(url) }
        return .ignore
    }

    fileprivate var folder: URL? { handler.folder }
}

extension DocumentWebView: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isClick = navigationAction.navigationType == .linkActivated
        switch Self.action(for: navigationAction.request.url, isClick: isClick, folder: folder) {
        case .allow:
            decisionHandler(.allow)
        case .browser(let url):
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        case .document(let url):
            decisionHandler(.cancel)
            onOpenDocument(url)
        case .ignore:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoaded()
    }

    /// No pop-up windows; a link meant for a new window is handled like any click.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        switch Self.action(for: navigationAction.request.url, isClick: true, folder: folder) {
        case .browser(let url): NSWorkspace.shared.open(url)
        case .document(let url): onOpenDocument(url)
        case .allow, .ignore: break
        }
        return nil
    }
}

/// Serves `hook-doc://doc/` (the page) and images inside the document's folder; fails anything else.
@MainActor final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    let page: Data
    let folder: URL?

    init(page: Data, folder: URL?) {
        self.page = page
        self.folder = folder
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        let path = url.path(percentEncoded: false)
        if path.isEmpty || path == "/" {
            return respond(task, url: url, data: page, mime: "text/html")
        }
        // Checked and read the way a click's check reads (`FileAccess.check`): the bytes come
        // from the descriptor the checks ran on.
        guard let folder, let image = DocumentPage.image(for: url, in: folder) else { return fail(task) }
        respond(task, url: url, data: image.data, mime: image.mime)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                   textEncodingName: mime == "text/html" ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}
