import Foundation
import RelayCore

/// The viewer's page: one HTML document Hook builds from a file's text. No part of the file
/// becomes markup here: the text is HTML-escaped into a hidden `<pre>`, and the viewer's own
/// script (`viewer.js`, after marked and DOMPurify) renders a Markdown file from it.
public enum DocumentPage {
    /// The scheme the viewer serves its page and the document folder's images under.
    public static let scheme = "hook-doc"
    /// The page's address; relative images resolve against it.
    public static let pageURL = URL(string: "\(scheme)://doc/")!

    /// What a file larger than this opens in instead of the viewer (its default app).
    public static let maxBytes = 8 * 1024 * 1024
    /// The largest image the page may load from the document's folder.
    public static let maxImageBytes = 20 * 1024 * 1024

    /// Nothing loads from anywhere but Hook's own scheme, and only images and the inline
    /// stylesheet at that. Scripts are off for the page altogether (`allowsContentJavaScript`);
    /// this is the second fence.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src \(scheme):; style-src 'unsafe-inline'; script-src 'none'; "
        + "form-action 'none'; base-uri 'none'; frame-src 'none'"

    /// The page for `text`, as `kind`, titled `title`, styled with `stylesheet`.
    public static func html(text: String, kind: DocumentKind, title: String, stylesheet: String) -> String {
        let body: String
        switch kind {
        case .markdown:
            // viewer.js replaces #hook-doc's content and removes #hook-source.
            body = "<main id=\"hook-doc\"></main>\n<pre id=\"hook-source\" hidden>\(escape(text))</pre>"
        case .plain:
            body = "<main id=\"hook-doc\"><pre class=\"plain\">\(escape(text))</pre></main>"
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// `&`, `<`, `>`, `"` and `'` as entities: the text can't close the element it sits in.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// The file's text: UTF-8, with anything that isn't replaced by U+FFFD.
    public static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: Images from the document's folder

    /// The image types the page may load, by extension, and their MIME types. No SVG (it
    /// carries script and links) and no WebP.
    public static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "heic": "image/heic",
    ]
    /// The checked type each image must have, by exact identifier, and its MIME type.
    public static let imageIdentifiers: [String: String] = [
        "public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif",
        "public.heic": "image/heic",
    ]

    /// An image the page loads: the file the check opened, its MIME type, and its bytes.
    public struct PageImage: Equatable {
        public let url: URL
        public let mime: String
        public let data: Data
    }

    /// The image a page request names inside `folder`, read the way a file row's Open reads
    /// (`FileAccess.check`): the descriptor walk with its local-disk rule, no execute bit,
    /// a type exactly on `imageIdentifiers` (and `DocumentPolicy`'s list), at most
    /// `maxImageBytes`, read from the checked descriptor, the file inside the resolved
    /// folder, and bytes that start with the type's signature (`hasSignature`). Nil for anything else: another host, a path that climbs out, another type.
    public static func image(for request: URL, in folder: URL) -> PageImage? {
        guard let target = target(for: request, in: folder),
              imageTypes[(target.lexical as NSString).pathExtension.lowercased()] != nil,
              case .document(let file) = FileAccess.check(target.lexical, readingUpTo: { _ in maxImageBytes }),
              let data = file.contents, !file.tooLarge,
              file.url.path(percentEncoded: false).hasPrefix(target.rootPrefix),
              let mime = imageIdentifiers[file.type.identifier.lowercased()],
              hasSignature(of: mime, data) else { return nil }
        return PageImage(url: file.url, mime: mime, data: data)
    }

    /// The HEIC brands an image's `ftyp` box may name (bytes 8-11).
    static let heicBrands: Set<String> = ["heic", "heix", "mif1", "msf1"]

    /// `data` starts with the signature of `mime`: PNG `89 50 4E 47 0D 0A 1A 0A`, JPEG
    /// `FF D8 FF`, GIF `GIF87a` or `GIF89a`, HEIC an `ftyp` box (bytes 4-7) with a brand on
    /// `heicBrands` (bytes 8-11). A file whose bytes are another format (WebP named `.png`)
    /// is no image.
    static func hasSignature(of mime: String, _ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
        switch mime {
        case "image/png": return starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg": return starts([0xFF, 0xD8, 0xFF])
        case "image/gif": return starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8))
        case "image/heic":
            guard bytes.count == 12, bytes[4..<8].elementsEqual("ftyp".utf8) else { return false }
            return heicBrands.contains(String(decoding: bytes[8..<12], as: UTF8.self))
        default: return false
        }
    }

    /// The file a page request (an image, or a link) names inside `folder`, resolved. In
    /// order, so nothing is touched before the lexical checks pass: the percent-decoded
    /// path has no empty, "." or ".." segment and no control character; the folder plus the
    /// path stays under the folder and isn't a network path or a hidden root
    /// (`FileAccess.isUntouchable`); only then `FileAccess.resolve` walks it (every step and
    /// every folder's file system checked), and the result must still be inside the
    /// resolved folder. Nil for anything else, a missing file included.
    public static func localFile(for request: URL, in folder: URL) -> URL? {
        guard let target = target(for: request, in: folder),
              case .path(let resolved) = FileAccess.resolve(target.lexical),
              resolved.hasPrefix(target.rootPrefix) else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    /// The lexical checks of `localFile`, and the folder resolved: the path to walk and the
    /// prefix the resolved file must have.
    static func target(for request: URL, in folder: URL) -> (lexical: String, rootPrefix: String)? {
        guard request.scheme?.lowercased() == scheme, request.host() == pageURL.host() else { return nil }
        let path = request.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        let relative = String(path.dropFirst())
        guard !relative.isEmpty,
              !relative.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !relative.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let rootPath = FileAccess.canonical(folder.path(percentEncoded: false))
        guard rootPath.hasPrefix("/"), !FileAccess.isUntouchable(rootPath) else { return nil }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        let lexical = prefix + relative
        guard FileAccess.canonical(lexical).hasPrefix(prefix), !FileAccess.isUntouchable(lexical),
              case .path(let root) = FileAccess.resolve(rootPath) else { return nil }
        return (lexical, root == "/" ? "/" : root + "/")
    }

    // MARK: Bundled scripts

    /// The scripts the viewer injects, in order: marked, DOMPurify, then Hook's renderer.
    public static let scriptNames = ["marked.umd.js", "purify.min.js", "viewer.js"]

    /// The folder holding the vendored scripts: in Hook.app's Resources (scripts/build.sh
    /// copies it there), else in the SwiftPM resource bundle next to the executable or the
    /// test bundle. Never `Bundle.module`, which stops the app when its build folder is gone.
    public static func resourceFolder() -> URL? {
        let bundleName = "Relay_RelayUI.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: "Viewer")) }
        candidates.append(Bundle.main.bundleURL.appending(path: bundleName).appending(path: "Viewer"))
        let here = Bundle(for: BundleMarker.self).bundleURL
        candidates.append(here.deletingLastPathComponent().appending(path: bundleName).appending(path: "Viewer"))
        candidates.append(here.appending(path: "Contents/Resources").appending(path: bundleName).appending(path: "Viewer"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: scriptNames[0]).path) }
    }

    /// The three scripts' sources, or nil when any is missing.
    public static func scripts() -> [String]? {
        guard let folder = resourceFolder() else { return nil }
        var out: [String] = []
        for name in scriptNames {
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            out.append(String(decoding: data, as: UTF8.self))
        }
        return out
    }
}

private final class BundleMarker {}
