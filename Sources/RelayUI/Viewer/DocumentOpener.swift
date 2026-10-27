import AppKit
import RelayCore
import UniformTypeIdentifiers

/// What a file row's buttons do. The app builds one over `DocumentOpener`; the gallery and
/// tests use `.none` or their own. A row first runs `check` on the path (off the main
/// actor), and only a `.document` result reaches `open`, `openWith` or `openWithOther`,
/// which take the checked file: its resolved URL, never the path the ask named.
public struct FileActions: Sendable {
    /// The click-time checks (`FileAccess.check`); never called while a row renders. The
    /// live one also reads the file's bytes when Open would show it in the viewer.
    public var check: @Sendable (String) async -> FileCheck
    public var open: @MainActor @Sendable (CheckedFile) -> Void
    public var openWith: @MainActor @Sendable (CheckedFile, URL) -> Void
    /// Open With › Other…: pick an app, then open the file in it.
    public var openWithOther: @MainActor @Sendable (CheckedFile) -> Void
    public var reveal: @MainActor @Sendable (URL) -> Void
    /// The apps that open files named like this (by type, never the file): the default
    /// first, then the rest by name.
    public var apps: @MainActor @Sendable (String) -> [URL]

    public init(check: @escaping @Sendable (String) async -> FileCheck,
                open: @escaping @MainActor @Sendable (CheckedFile) -> Void,
                openWith: @escaping @MainActor @Sendable (CheckedFile, URL) -> Void,
                openWithOther: @escaping @MainActor @Sendable (CheckedFile) -> Void,
                reveal: @escaping @MainActor @Sendable (URL) -> Void,
                apps: @escaping @MainActor @Sendable (String) -> [URL]) {
        self.check = check
        self.open = open
        self.openWith = openWith
        self.openWithOther = openWithOther
        self.reveal = reveal
        self.apps = apps
    }

    public static let none = FileActions(check: { _ in .missing }, open: { _ in }, openWith: { _, _ in },
                                         openWithOther: { _ in }, reveal: { _ in }, apps: { _ in [] })

    /// The real thing: Open goes where `target()` (Settings › Open documents in) says.
    @MainActor public static func live(target: @escaping @MainActor @Sendable () -> DocumentTarget) -> FileActions {
        FileActions(
            check: { path in
                let target = await target()
                return await Task.detached(priority: .userInitiated) {
                    FileAccess.check(path, readingUpTo: { DocumentOpener.viewerLimit($0, target: target) })
                }.value
            },
            open: { DocumentOpener.open($0, target: target()) },
            openWith: { DocumentOpener.open($0, withApp: $1) },
            openWithOther: { file in
                if let app = DocumentApps.choose(title: "Open “\(file.url.lastPathComponent)” With") {
                    DocumentOpener.open(file, withApp: app)
                }
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            apps: { DocumentApps.apps(forName: $0) })
    }
}

/// Opens a document where the owner wants it. Every route takes a file a click's
/// `FileAccess.check` passed (its resolved URL and checked type), refuses again what
/// `DocumentPolicy` refuses, and never falls back to anything the check didn't choose:
/// no bare `NSWorkspace.open`, always a named app for the checked type, and only while
/// the path still names the checked file (`FileAccess.isUnchanged`).
@MainActor public enum DocumentOpener {
    /// What a click on Open does with a checked file.
    public enum Plan: Equatable {
        /// Show these bytes (the ones the check read) in Hook's viewer.
        case viewer(Data, DocumentKind)
        /// Open the file in this app.
        case app(URL)
        /// Beep and open nothing.
        case refuse
    }

    /// How much of `file` the check reads for the viewer: `DocumentPage.maxBytes` when Open
    /// would show it there, else nothing.
    nonisolated public static func viewerLimit(_ file: URL, target: DocumentTarget) -> Int? {
        target.route(DocumentKind(fileExtension: file.pathExtension)) == .viewer ? DocumentPage.maxBytes : nil
    }

    /// Where Open sends `file`. The viewer shows only the bytes the check read: when the
    /// read failed for any reason but the size, nothing opens. A file too large for the
    /// viewer, the default app and a missing chosen app all mean the default app for the
    /// checked type. `chosen` and `defaultApp` are `DocumentApps`'; tests pass their own.
    public static func plan(_ file: CheckedFile, target: DocumentTarget,
                            chosen: (String) -> URL? = { DocumentApps.url(for: $0) },
                            defaultApp: (UTType) -> URL? = { DocumentApps.defaultApp(for: $0) }) -> Plan {
        guard allows(file) else { return .refuse }
        let kind = DocumentKind(fileExtension: file.url.pathExtension)
        switch target.route(kind) {
        case .viewer:
            if let kind, let contents = file.contents { return .viewer(contents, kind) }
            guard file.tooLarge else { return .refuse }
            return plan(file, withApp: defaultApp(file.type))
        case .defaultApp:
            return plan(file, withApp: defaultApp(file.type))
        case .app(let id):
            return plan(file, withApp: chosen(id) ?? defaultApp(file.type))
        }
    }

    /// Opening `file` in `app`: only a document the policy allows (by name and checked type),
    /// an app `DocumentApps` doesn't refuse, and a path that still names the checked file.
    public static func plan(_ file: CheckedFile, withApp app: URL?) -> Plan {
        guard let app, allows(file), !DocumentApps.isRefused(app), FileAccess.isUnchanged(file) else { return .refuse }
        return .app(app)
    }

    public static func open(_ file: CheckedFile, target: DocumentTarget) {
        run(plan(file, target: target), file)
    }

    public static func open(_ file: CheckedFile, withApp app: URL) {
        run(plan(file, withApp: app), file)
    }

    static func allows(_ file: CheckedFile) -> Bool {
        let path = file.url.path(percentEncoded: false)
        return DocumentPolicy.allows(fileName: path) && DocumentPolicy.allows(type: file.type, fileName: path)
    }

    private static func run(_ plan: Plan, _ file: CheckedFile) {
        switch plan {
        case .viewer(let contents, let kind):
            if !DocumentViewer.shared.show(file.url, contents: contents, kind: kind) { NSSound.beep() }
        case .app(let app):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file.url], withApplicationAt: app, configuration: configuration) { _, error in
                if error != nil { Task { @MainActor in NSSound.beep() } }
            }
        case .refuse:
            NSSound.beep()
        }
    }
}

/// Apps that open documents, by type (never by reading the file).
@MainActor public enum DocumentApps {
    /// The default app for the type the name declares first, then the others by name; none
    /// twice, and never a terminal, Script Editor or Automator. None for a name
    /// `DocumentPolicy` refuses.
    public static func apps(forName fileName: String) -> [URL] {
        guard DocumentPolicy.allows(fileName: fileName) else { return [] }
        let type = DocumentPolicy.type(fileName: fileName)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: type)
        let first = NSWorkspace.shared.urlForApplication(toOpen: type)
        var seen = Set<String>()
        var out: [URL] = []
        for app in ([first].compactMap { $0 } + all.sorted { name($0) < name($1) })
        where !isRefused(app) && seen.insert(app.standardizedFileURL.path).inserted {
            out.append(app)
        }
        return out
    }

    /// The default app for `type` (the checked one), unless `isRefused` refuses it.
    public static func defaultApp(for type: UTType) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: type), !isRefused(app) else { return nil }
        return app
    }

    /// A terminal, Script Editor, Automator, Python Launcher, or an app either of the first
    /// two saved (`DocumentPolicy.refusesApp`): left out of every list and never opened with.
    public static func isRefused(_ app: URL) -> Bool {
        let bundle = Bundle(url: app)
        let executable = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        return DocumentPolicy.refusesApp(bundleID: bundle?.bundleIdentifier, name: app.lastPathComponent,
                                         executable: executable)
            || DocumentPolicy.refusesApp(bundleID: nil, name: name(app))
    }

    /// An app's display name ("TextEdit").
    public static func name(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// A stored choice (a bundle id or a path) → the app, when it is installed.
    public static func url(for id: String) -> URL? {
        if id.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: id) ? URL(fileURLWithPath: id) : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    /// What Settings stores for `app`: its bundle id, or its path when it has none.
    public static func configValue(for app: URL) -> String {
        Bundle(url: app)?.bundleIdentifier ?? app.path
    }

    /// The app picker: /Applications, apps only.
    public static func choose(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard !isRefused(url) else {
            NSSound.beep()
            return nil
        }
        return url
    }
}
