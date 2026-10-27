import Foundation
import RelayCore
import Testing
import UniformTypeIdentifiers
@testable import RelayUI

/// The viewer's page, its image fence and its link rules.
@Suite @MainActor struct DocumentViewerTests {
    @Test func theTextCannotBecomeMarkup() {
        let html = DocumentPage.html(text: "</pre><script>alert(1)</script>&\"'", kind: .markdown,
                                     title: "<b>x</b>.md", stylesheet: "")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt;&amp;&quot;&#39;"))
        #expect(html.contains("<title>&lt;b&gt;x&lt;/b&gt;.md</title>"))
        #expect(html.contains("<pre id=\"hook-source\" hidden>"))
        #expect(html.contains("<main id=\"hook-doc\"></main>"))
    }

    @Test func plainTextIsMonospaceWithoutTheRenderer() {
        let html = DocumentPage.html(text: "a  b\n<c>", kind: .plain, title: "t.txt", stylesheet: "")
        #expect(html.contains("<pre class=\"plain\">a  b\n&lt;c&gt;</pre>"))
        #expect(!html.contains("hook-source"))
    }

    @Test func thePageLoadsNothingFromOutside() {
        let html = DocumentPage.html(text: "x", kind: .markdown, title: "t.md", stylesheet: "")
        #expect(html.contains("Content-Security-Policy"))
        let csp = DocumentPage.contentSecurityPolicy
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("script-src 'none'"))
        #expect(csp.contains("img-src hook-doc:;"))
        #expect(!csp.contains("http"))
        #expect(DocumentWebView.rules.contains("\"block\""))
        #expect(DocumentWebView.rules.contains("^hook-doc:"))
    }

    @Test func openWithLeavesOutTerminalsAndScriptRunners() {
        #expect(DocumentApps.isRefused(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")))
        #expect(DocumentApps.isRefused(URL(fileURLWithPath: "/System/Applications/Utilities/Script Editor.app")))
        #expect(DocumentApps.isRefused(URL(fileURLWithPath: "/Applications/Ghostty.app")))
        #expect(DocumentApps.isRefused(URL(fileURLWithPath: "/Applications/Python 3.13/Python Launcher.app")))
        #expect(DocumentApps.isRefused(URL(fileURLWithPath: "/Applications/Hyper.app")))
        #expect(DocumentApps.isRefused(URL(fileURLWithPath: "/Applications/Tabby.app")))
        #expect(!DocumentApps.isRefused(URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
        for name in ["plan.txt", "plan.md", "notes.rtf", "a.pdf"] {
            #expect(DocumentApps.apps(forName: name).allSatisfy { !DocumentApps.isRefused($0) }, "\(name)")
        }
    }

    /// An app Script Editor or Automator saved runs its script, whatever it is called: its
    /// executable gives it away, and so does a saved applet's bundle id.
    @Test func savedScriptAppsAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, id: String, executable: String) throws -> URL {
            let url = root.appending(path: name + ".app")
            try FileManager.default.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": executable,
                                       "CFBundlePackageType": "APPL", "CFBundleName": name]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url.appending(path: "Contents/Info.plist"))
            return url
        }
        #expect(DocumentApps.isRefused(try app("Viewer Helper", id: "com.example.helper", executable: "applet")))
        #expect(DocumentApps.isRefused(try app("Pdf Tool", id: "com.example.pdftool", executable: "Application Stub")))
        #expect(DocumentApps.isRefused(try app("Drop Box", id: "com.example.dropbox-helper", executable: "droplet")))
        #expect(DocumentApps.isRefused(try app("Batch Rename", id: "org.example.batch", executable: "Automator Application Stub")))
        #expect(DocumentApps.isRefused(try app("Notes Opener", id: "com.apple.ScriptEditor.id.Notes-Opener",
                                                executable: "NotesOpener")))
        #expect(DocumentApps.isRefused(try app("Flow", id: "com.apple.automator.Flow", executable: "Flow")))
        #expect(DocumentApps.isRefused(try app("Shell", id: "com.raphaelamorim.rio", executable: "rio")))
        #expect(!DocumentApps.isRefused(try app("Writer", id: "com.example.writer", executable: "Writer")))
    }

    /// Open goes only where the check allows: the viewer with the checked bytes, or a named
    /// app for the checked type. No read, a refused app, no app or a swapped file: nothing.
    @Test func openPlansNeverFallBack() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "open-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appending(path: "plan.md")
        try Data("# Plan".utf8).write(to: doc)
        let pdf = folder.appending(path: "r.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let editor = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        var asked: [UTType] = []
        let fallback: (UTType) -> URL? = { asked.append($0); return editor }

        let read = try #require(FileAccess.check(doc.path, readingUpTo: { _ in 100 }).checked)
        #expect(DocumentOpener.plan(read, target: .viewer, defaultApp: fallback) == .viewer(Data("# Plan".utf8), .markdown))
        // Asked to read, the bytes didn't come: never the default app instead.
        let unread = try #require(FileAccess.check(doc.path).checked)
        #expect(DocumentOpener.plan(unread, target: .viewer, defaultApp: fallback) == .refuse)
        // Too large for the viewer: the default app for the checked type.
        let large = try #require(FileAccess.check(doc.path, readingUpTo: { _ in 2 }).checked)
        #expect(DocumentOpener.plan(large, target: .viewer, defaultApp: fallback) == .app(editor))
        #expect(asked == [large.type])

        let checkedPDF = try #require(FileAccess.check(pdf.path).checked)
        #expect(DocumentOpener.plan(checkedPDF, target: .systemDefault, defaultApp: { _ in editor }) == .app(editor))
        #expect(DocumentOpener.plan(checkedPDF, target: .systemDefault, defaultApp: { _ in nil }) == .refuse)
        #expect(DocumentOpener.plan(checkedPDF, target: .systemDefault, defaultApp: { _ in terminal }) == .refuse)
        #expect(DocumentOpener.plan(checkedPDF, target: .app("com.example.gone"), chosen: { _ in nil },
                                    defaultApp: { _ in editor }) == .app(editor))
        #expect(DocumentOpener.plan(checkedPDF, target: .app("com.example.term"), chosen: { _ in terminal },
                                    defaultApp: { _ in editor }) == .refuse)
        #expect(DocumentOpener.plan(checkedPDF, withApp: terminal) == .refuse)
        #expect(DocumentOpener.plan(checkedPDF, withApp: editor) == .app(editor))
        // A checked type the policy refuses is refused whatever the name says.
        let html = CheckedFile(url: checkedPDF.url, type: .html, device: checkedPDF.device, inode: checkedPDF.inode)
        #expect(DocumentOpener.plan(html, withApp: editor) == .refuse)

        // The swap: the checked file is replaced by a symlink between the check and the open.
        try FileManager.default.removeItem(at: pdf)
        try FileManager.default.createSymbolicLink(at: pdf, withDestinationURL: doc)
        #expect(DocumentOpener.plan(checkedPDF, withApp: editor) == .refuse)
        #expect(DocumentOpener.plan(checkedPDF, target: .systemDefault, defaultApp: { _ in editor }) == .refuse)
    }

    @Test func theDefaultAppIsNeverARefusedOne() {
        for type in [UTType.plainText, .pdf, .png] {
            if let app = DocumentApps.defaultApp(for: type) { #expect(!DocumentApps.isRefused(app)) }
        }
    }

    @Test func theWebViewHasNoLinkPreviews() {
        let view = DocumentWebView(page: "<p>x</p>", folder: nil)
        #expect(!view.webView.allowsLinkPreview)
        #expect(!view.webView.allowsBackForwardNavigationGestures)
        #expect(!view.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @Test func theStylesheetHasBothAppearances() {
        let css = DS.Viewer.stylesheet()
        #expect(css.contains("prefers-color-scheme: dark"))
        #expect(css.contains("--text: rgba("))
        #expect(!css.contains("url("))
        #expect(!css.contains("@import"))
    }

    @Test func theScriptsAreBundled() throws {
        let scripts = try #require(DocumentPage.scripts())
        #expect(scripts.count == 3)
        #expect(scripts[0].contains("marked v18.0.14"))
        #expect(scripts[1].contains("DOMPurify 3.4.16"))
        #expect(scripts[2].contains("DOMPurify.sanitize"))
    }

    @Test func imagesComeOnlyFromTheDocumentsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "viewer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder.appending(path: "img"), withIntermediateDirectories: true)
        try Self.pngBytes.write(to: folder.appending(path: "img/chart.png"))
        try Self.pngBytes.write(to: root.appending(path: "secret.png"))
        try Data("x".utf8).write(to: folder.appending(path: "notes.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "escape.png"),
                                                   withDestinationURL: root.appending(path: "secret.png"))

        let ok = try #require(DocumentPage.image(for: URL(string: "hook-doc://doc/img/chart.png")!, in: folder))
        #expect(ok.mime == "image/png")
        #expect(ok.url.lastPathComponent == "chart.png")
        #expect(DocumentPage.image(for: URL(string: "hook-doc://doc/../secret.png")!, in: folder) == nil)
        #expect(DocumentPage.image(for: URL(string: "hook-doc://doc/img/%2E%2E/%2E%2E/secret.png")!, in: folder) == nil)
        #expect(DocumentPage.image(for: URL(string: "hook-doc://doc/escape.png")!, in: folder) == nil)
        #expect(DocumentPage.image(for: URL(string: "hook-doc://doc/notes.txt")!, in: folder) == nil)
        #expect(DocumentPage.image(for: URL(string: "hook-doc://other/img/chart.png")!, in: folder) == nil)
        #expect(DocumentPage.image(for: URL(string: "https://doc/img/chart.png")!, in: folder) == nil)
    }

    /// Images go through the click's check: the exact type list (no SVG, no WebP), no
    /// execute bit, the size limit, and the bytes from the checked descriptor.
    @Test func imagesAreCheckedAndReadLikeDocuments() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "viewer-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bodies: [String: Data] = ["a.png": Self.pngBytes, "b.jpg": Self.jpegBytes, "c.jpeg": Self.jpegBytes,
                                      "d.gif": Self.gifBytes, "e.heic": Self.heicBytes, "run.png": Self.pngBytes]
        for name in ["a.png", "b.jpg", "c.jpeg", "d.gif", "e.heic", "f.svg", "g.webp", "h.tiff", "run.png"] {
            try (bodies[name] ?? Data("img \(name)".utf8)).write(to: folder.appending(path: name))
        }
        #expect(chmod(folder.appending(path: "run.png").path, 0o755) == 0)
        func image(_ name: String) -> DocumentPage.PageImage? {
            DocumentPage.image(for: URL(string: "hook-doc://doc/" + name)!, in: folder)
        }
        #expect(image("a.png")?.mime == "image/png")
        #expect(image("a.png")?.data == Self.pngBytes)
        #expect(image("b.jpg")?.mime == "image/jpeg")
        #expect(image("c.jpeg")?.mime == "image/jpeg")
        #expect(image("d.gif")?.mime == "image/gif")
        #expect(image("e.heic")?.mime == "image/heic")
        for refused in ["f.svg", "g.webp", "h.tiff", "run.png", "gone.png"] {
            #expect(image(refused) == nil, "\(refused)")
        }
        #expect(DocumentPage.imageTypes["svg"] == nil && DocumentPage.imageTypes["webp"] == nil)
        #expect(Set(DocumentPage.imageIdentifiers.keys).isSubset(of: DocumentPolicy.allowedIdentifiers))
        // Too large for the page: refused, not cut short.
        let big = folder.appending(path: "big.png")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        #expect(truncate(big.path, off_t(DocumentPage.maxImageBytes + 1)) == 0)
        #expect(image("big.png") == nil)
    }

    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) + Data("IHDR".utf8)
    static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]) + Data("JFIF".utf8)
    static let gifBytes = Data("GIF89a".utf8) + Data([1, 0, 1, 0])
    static let heicBytes = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data([0, 0, 0, 0]) + Data("mif1heic".utf8)
    static let webpBytes = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WEBPVP8 ".utf8)

    /// An image loads only when its bytes start with its checked type's signature: a `.png`
    /// holding WebP or a `.jpg` holding PNG is no image, and each allowed type (every HEIC
    /// brand too) loads.
    @Test func imagesMustCarryTheirTypesSignature() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "viewer-magic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func heic(_ brand: String) -> Data { Data([0, 0, 0, 0x18]) + Data("ftyp\(brand)".utf8) + Data([0, 0, 0, 0]) }
        let files: [String: Data] = [
            "webp.png": Self.webpBytes, "png.jpg": Self.pngBytes, "gif.png": Self.gifBytes, "jpeg.gif": Self.jpegBytes,
            "avif.heic": heic("avif"), "short.heic": Data("ftyp".utf8), "empty.png": Data(), "gif88.gif": Data("GIF88a".utf8),
            "ok.png": Self.pngBytes, "ok.jpg": Self.jpegBytes, "ok.jpeg": Self.jpegBytes, "ok.gif": Self.gifBytes,
            "old.gif": Data("GIF87a".utf8) + Data([1, 0, 1, 0]), "heic.heic": heic("heic"), "heix.heic": heic("heix"),
            "mif1.heic": heic("mif1"), "msf1.heic": heic("msf1"),
        ]
        for (name, data) in files { try data.write(to: folder.appending(path: name)) }
        func image(_ name: String) -> DocumentPage.PageImage? {
            DocumentPage.image(for: URL(string: "hook-doc://doc/" + name)!, in: folder)
        }
        for refused in ["webp.png", "png.jpg", "gif.png", "jpeg.gif", "avif.heic", "short.heic", "empty.png", "gif88.gif"] {
            #expect(image(refused) == nil, "\(refused)")
        }
        let loads: [String: String] = [
            "ok.png": "image/png", "ok.jpg": "image/jpeg", "ok.jpeg": "image/jpeg", "ok.gif": "image/gif",
            "old.gif": "image/gif", "heic.heic": "image/heic", "heix.heic": "image/heic", "mif1.heic": "image/heic",
            "msf1.heic": "image/heic",
        ]
        for (name, mime) in loads {
            #expect(image(name)?.mime == mime, "\(name)")
            #expect(image(name)?.data == files[name], "\(name)")
        }
    }

    /// Image and link paths are checked lexically after percent-decoding before anything is
    /// touched, then resolved with FileAccess (network roots and file systems included).
    @Test func pagePathsAreCheckedBeforeTheyAreResolved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "viewer-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder.appending(path: "img"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "img/chart.png"))
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "remote.png").path,
                                                   withDestinationPath: "/net/h/a.png")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "vol.png").path,
                                                   withDestinationPath: "/.vol/1/2")
        func file(_ address: String) -> URL? { DocumentPage.localFile(for: URL(string: address)!, in: folder) }

        let real = try #require(file("hook-doc://doc/img/chart.png"))
        #expect(real.path.hasSuffix("/docs/img/chart.png"))
        #expect(!real.path.hasPrefix("/var/"))
        for refused in ["hook-doc://doc/..%2F..%2Fnet%2Fh%2Fa.png", "hook-doc://doc/img/..%2F..%2Fnet%2Fh%2Fa.png",
                        "hook-doc://doc/img//chart.png", "hook-doc://doc//img/chart.png", "hook-doc://doc/./img/chart.png",
                        "hook-doc://doc/img/%2E/chart.png", "hook-doc://doc/img/", "hook-doc://doc/img/chart.png%00.md",
                        "hook-doc://doc/remote.png", "hook-doc://doc/vol.png", "hook-doc://doc/img/gone.png"] {
            #expect(file(refused) == nil, "\(refused)")
            #expect(DocumentPage.image(for: URL(string: refused)!, in: folder) == nil, "\(refused)")
        }
        // A folder that is itself a network path is never walked.
        #expect(DocumentPage.localFile(for: URL(string: "hook-doc://doc/a.png")!,
                                       in: URL(fileURLWithPath: "/net/h")) == nil)
        #expect(DocumentPage.localFile(for: URL(string: "hook-doc://doc/a.png")!,
                                       in: URL(fileURLWithPath: "/System/Volumes/Data/home/u")) == nil)
    }

    /// The viewer renders the bytes the check read: the file can change or go after the
    /// check and the page still shows what was checked.
    @Test func theViewerRendersTheCheckedBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "viewer-bytes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appending(path: "plan.md")
        try Data("checked text".utf8).write(to: doc)
        let limit = DocumentOpener.viewerLimit(doc, target: .viewer)
        #expect(limit == DocumentPage.maxBytes)
        #expect(DocumentOpener.viewerLimit(doc, target: .systemDefault) == nil)
        #expect(DocumentOpener.viewerLimit(folder.appending(path: "r.pdf"), target: .viewer) == nil)
        guard case .document(let file) = FileAccess.check(doc.path, readingUpTo: { _ in limit }) else {
            Issue.record("not a document"); return
        }
        try Data("swapped text".utf8).write(to: doc)
        try FileManager.default.removeItem(at: doc)
        let contents = try #require(file.contents)
        let page = try #require(DocumentViewer.page(file.url, contents: contents, kind: .markdown))
        #expect(page.contains("checked text"))
        #expect(!page.contains("swapped"))
        #expect(DocumentViewer.page(file.url, contents: Data(count: DocumentPage.maxBytes + 1), kind: .plain) == nil)
    }

    @Test func linkClicks() throws {
        let made = FileManager.default.temporaryDirectory.appending(path: "viewer-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        try Data("x".utf8).write(to: made.appending(path: "next.md"))
        try Data("x".utf8).write(to: made.appending(path: "run.command"))
        let folder = URL(fileURLWithPath: FileAccess.canonical(try #require(realpath(made.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })))
        typealias A = DocumentWebView.LinkAction
        #expect(DocumentWebView.action(for: DocumentPage.pageURL, isClick: false, folder: folder) == A.allow)
        #expect(DocumentWebView.action(for: URL(string: "hook-doc://doc/#dates"), isClick: true, folder: folder) == A.allow)
        let web = URL(string: "https://status.example.com/a")!
        #expect(DocumentWebView.action(for: web, isClick: true, folder: folder) == A.browser(web))
        #expect(DocumentWebView.action(for: web, isClick: false, folder: folder) == A.ignore)
        #expect(DocumentWebView.action(for: URL(string: "hook-doc://doc/next.md"), isClick: true, folder: folder)
            == A.document(folder.appending(path: "next.md")))
        #expect(DocumentWebView.action(for: URL(string: "hook-doc://doc/run.command"), isClick: true, folder: folder)
            == A.ignore)
        #expect(DocumentWebView.action(for: URL(string: "hook-doc://doc/../../x.md"), isClick: true, folder: folder)
            == A.ignore)
        #expect(DocumentWebView.action(for: URL(string: "hook-doc://doc/..%2F..%2Fnet%2Fh%2Fa.md"), isClick: true,
                                       folder: folder) == A.ignore)
        #expect(DocumentWebView.action(for: URL(string: "hook-doc://doc/gone.md"), isClick: true, folder: folder)
            == A.ignore)
        #expect(DocumentWebView.action(for: URL(string: "file:///etc/hosts"), isClick: true, folder: folder) == A.ignore)
        #expect(DocumentWebView.action(for: URL(string: "javascript:alert(1)"), isClick: true, folder: folder) == A.ignore)
    }
}

/// A step whose only body is a file still opens to show its file row.
@Suite struct FileStepBodyTests {
    @Test func aFileIsABody() {
        #expect(StepRow.hasBody(StepContent(action: "Read the plan", file: "~/plan.md")))
        #expect(!StepRow.hasBody(StepContent(action: "Read the plan")))
        #expect(FileRow.accessibilityLabel(name: "plan.md", detail: "File not found") == "plan.md, File not found")
    }
}

extension FileCheck {
    /// The checked file of a `.document` result.
    var checked: CheckedFile? {
        if case .document(let file) = self { return file }
        return nil
    }
}
