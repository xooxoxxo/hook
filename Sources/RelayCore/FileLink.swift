import Foundation

/// A step's `file` or a link's `path`: a local document the owner should read. The raw
/// value is untrusted; the view passes `name` and `folder` through `line()`.
/// Hook never touches the file to show the row (no stat, no attributes, no icon from the
/// file): only a click checks it, through `FileAccess.check`.
public struct FileLink: Equatable, Sendable {
    /// The path as sent ("/…" or "~/…").
    public let raw: String
    /// The path with a leading "~" expanded and then made canonical without the filesystem
    /// (`FileAccess.canonical`): what the row shows and what a click checks.
    public let path: String

    /// Nil unless `raw` is an absolute local path ("/…" or "~/…") on one line, with no
    /// control character, as the validator requires.
    public init?(_ raw: String, home: String) {
        guard raw.hasPrefix("/") || raw.hasPrefix("~/"),
              !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        self.raw = raw
        path = FileAccess.canonical(TildePath.expand(raw, home: home))
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// The file name: the last path component ("brief.md").
    public var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// The folder, with the home folder written as "~" ("~/Documents/Plans").
    public func folder(home: String) -> String {
        TildePath.abbreviate((path as NSString).deletingLastPathComponent, home: home)
    }

    /// The lower-cased extension, without the dot ("md"); "" when there is none.
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }

    /// What Hook's own viewer shows for this file; nil when the viewer doesn't take it.
    public var viewerKind: DocumentKind? { DocumentKind(fileExtension: fileExtension) }
}

/// The kinds of document Hook's viewer renders.
public enum DocumentKind: String, Equatable, Sendable {
    /// .md and .markdown, rendered.
    case markdown
    /// .txt, in monospace.
    case plain

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "txt": self = .plain
        default: return nil
        }
    }
}

/// Whether a file row can open its file on this Mac.
public enum FilePlace: Equatable, Sendable {
    /// The ask came from this Mac.
    case here
    /// The ask came from another machine: the path means nothing here. nil: the ask doesn't
    /// say which one.
    case otherMac(String?)

    /// `askHost` is the ask's `from.host`, `localHost` this Mac's cached host name and
    /// `queueIsLocal` whether Hook reads This Mac's queue. With no host, an ask in This Mac
    /// mode is local (it was written here); from a mailbox it may come from any machine, so
    /// it is "From another machine". A host that can't be matched to this Mac is another one.
    public static func of(askHost: String?, localHost: String?, queueIsLocal: Bool) -> FilePlace {
        guard let host = askHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return queueIsLocal ? .here : .otherMac(nil)
        }
        if let localHost, HostName.same(host, localHost) { return .here }
        return .otherMac(host)
    }
}

/// What a file row shows and offers. The row works it out from the path alone; a click's
/// `FileCheck` can then turn an available row into missing, refused or network.
public enum FileRowState: Equatable, Sendable {
    /// On this Mac and a document type: Open, Open With, Reveal in Finder, Copy Path.
    case available
    /// On this Mac but not there (found at a click): "File not found", Copy Path only.
    case missing
    /// Not a document type (`DocumentPolicy`): Reveal in Finder and Copy Path only.
    case refused
    /// A network path or a hidden root (`FileAccess.isUntouchable`): Copy Path only, never
    /// touched.
    case network
    /// From another machine: "On <host>" (or "From another machine"), Copy Path only.
    case otherMac(String?)

    /// No filesystem: the place, then the path's own rules.
    public static func of(place: FilePlace, link: FileLink) -> FileRowState {
        if case .otherMac(let host) = place { return .otherMac(host) }
        if FileAccess.isUntouchable(link.path) { return .network }
        if !DocumentPolicy.allows(fileName: link.path) { return .refused }
        return .available
    }

    /// The state a click found; nil when the file is a document that opened.
    public static func after(_ check: FileCheck) -> FileRowState? {
        switch check {
        case .document: return nil
        case .refused: return .refused
        case .missing: return .missing
        case .network: return .network
        }
    }

    public static let notFound = "File not found"
    public static let networkNote = "Hook doesn't open network paths"
    public static let unknownMachine = "From another machine"

    /// The secondary line's text instead of the folder; nil when the folder shows.
    public var note: String? {
        switch self {
        case .available: return nil
        case .missing: return Self.notFound
        case .refused: return DocumentPolicy.refusedNote
        case .network: return Self.networkNote
        case .otherMac(let host?): return "On " + Sanitize.revealLine(host)
        case .otherMac(nil): return Self.unknownMachine
        }
    }

    public var canOpen: Bool { self == .available }
    /// Reveal in Finder: a file on this Mac that isn't on a network path.
    public var canReveal: Bool { self == .available || self == .refused }
}

/// Settings › General › "Open documents in", stored as config.json `openDocumentsIn`.
public enum DocumentTarget: Equatable, Sendable {
    /// Hook's viewer for Markdown and text; any other file opens in its default app.
    case viewer
    /// The file's default app.
    case systemDefault
    /// A chosen app: its bundle id, or the path to the app when it has none.
    case app(String)

    public static let viewerValue = "hook"
    public static let systemValue = "system"

    /// "hook" or missing or blank → the viewer, "system" → the default app, a bundle id
    /// (reverse-DNS, "com.example.writer") or an absolute path → that app. Anything else
    /// → the viewer.
    public init(config value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed {
        case "", Self.viewerValue: self = .viewer
        case Self.systemValue: self = .systemDefault
        // An app that runs what it opens (a terminal, Script Editor, Automator) is never the choice.
        default: self = Self.isAppID(trimmed) && !DocumentPolicy.refusesApp(id: trimmed) ? .app(trimmed) : .viewer
        }
    }

    /// A bundle id (two or more dot-separated parts of ASCII letters, digits and "-") or
    /// an absolute path.
    public static func isAppID(_ value: String) -> Bool {
        if value.hasPrefix("/") { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
        }
    }

    public var configValue: String {
        switch self {
        case .viewer: return Self.viewerValue
        case .systemDefault: return Self.systemValue
        case .app(let id): return id
        }
    }

    /// Where Open sends `kind` (nil: a file the viewer doesn't take).
    public func route(_ kind: DocumentKind?) -> DocumentRoute {
        switch self {
        case .viewer: return kind == nil ? .defaultApp : .viewer
        case .systemDefault: return .defaultApp
        case .app(let id): return .app(id)
        }
    }
}

/// Where one press of Open goes.
public enum DocumentRoute: Equatable, Sendable {
    case viewer
    case defaultApp
    case app(String)
}

/// One entry of the "Open documents in" picker.
public struct DocumentChoice: Equatable, Sendable, Identifiable {
    /// `DocumentTarget.configValue`, or `DocumentChoice.otherID`.
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// The picker's "Other App…" entry, which opens the app chooser instead of saving.
    public static let otherID = "\u{0}other"

    /// Hook's viewer, the default app, the chosen app (named, or by its id until the app has
    /// looked it up), then Other App….
    public static func options(current: String?, appName: String?) -> [DocumentChoice] {
        var options = [DocumentChoice(id: DocumentTarget.viewerValue, title: "Hook's viewer"),
                       DocumentChoice(id: DocumentTarget.systemValue, title: "The file's default app")]
        if case .app(let id) = DocumentTarget(config: current) {
            options.append(DocumentChoice(id: id, title: Sanitize.revealLine(appName ?? id)))
        }
        options.append(DocumentChoice(id: otherID, title: "Other App…"))
        return options
    }
}
