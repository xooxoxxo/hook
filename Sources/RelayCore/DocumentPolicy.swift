import Foundation
import UniformTypeIdentifiers

/// Which files Hook opens: documents only, by type. A file row never launches an app, a
/// script, an installer or a web page; those show "Hook doesn't open this kind of file"
/// and keep only Reveal in Finder and Copy Path. The same rule holds for every route:
/// Hook's viewer, the default app, the chosen app and Open With.
public enum DocumentPolicy {
    public static let refusedNote = "Hook doesn't open this kind of file"

    /// The only types Hook opens, by exact identifier (no conformance: a type that merely
    /// conforms to text or an image, such as SVG, HTML, a calendar or a contact, is
    /// refused): Markdown, plain text, CSV, JSON, logs (public.log, and com.apple.log, which
    /// macOS reports for .log), YAML, PDF, PNG, JPEG, HEIC, GIF, TIFF, MP3, MPEG-4 audio
    /// (public.mpeg-4-audio, and com.apple.m4a-audio, which macOS reports for .m4a) and video,
    /// QuickTime, and `officeIdentifiers`.
    public static let allowedIdentifiers: Set<String> = [
        "net.daringfireball.markdown", "public.plain-text", "public.comma-separated-values-text", "public.json",
        "public.log", "com.apple.log", "public.yaml", "com.adobe.pdf", "public.png", "public.jpeg", "public.heic",
        "com.compuserve.gif", "public.tiff", "public.mp3", "public.mpeg-4-audio", "com.apple.m4a-audio", "public.mpeg-4",
        "com.apple.quicktime-movie",
    ]
    /// The iWork and Office document types Hook opens, by identifier (a package one too):
    /// doc, docx, xls, xlsx, ppt, pptx, pps, ppsx, and Pages, Numbers and Keynote in their
    /// package and single-file forms. Nothing else from Microsoft or Office Open XML.
    public static let officeIdentifiers: Set<String> = [
        "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.excel.xls", "org.openxmlformats.spreadsheetml.sheet",
        "com.microsoft.powerpoint.ppt", "org.openxmlformats.presentationml.presentation",
        "com.microsoft.powerpoint.pps", "org.openxmlformats.presentationml.slideshow",
        "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages",
        "com.apple.iwork.numbers.numbers", "com.apple.iwork.numbers.sffnumbers",
        "com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey",
    ]

    /// The type that the file name's extension declares (public.data when unknown).
    public static func type(fileName: String) -> UTType {
        UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
    }

    /// No filesystem: the type the name's extension declares.
    public static func allows(fileName: String) -> Bool {
        allows(type: type(fileName: fileName), fileName: fileName)
    }

    /// `type` is the file's type (from its name, or the one a click read from the file): its
    /// identifier must be exactly one of `allowedIdentifiers` or `officeIdentifiers`.
    /// `fileName` is kept for the callers; the decision is the type's alone.
    public static func allows(type: UTType, fileName: String) -> Bool {
        let identifier = type.identifier.lowercased()
        return allowedIdentifiers.contains(identifier) || officeIdentifiers.contains(identifier)
    }

    /// Apps that run what they open: never in Open With, never an "Open documents in"
    /// choice, never what Hook opens a document in. By bundle id, by bundle id prefix (the
    /// apps Script Editor and Automator save), by name for a copy without one, and by the
    /// executable a saved script app runs.
    public static let refusedAppBundleIDs: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "dev.warp.warp", "dev.warp.warp-stable", "dev.warp.warp-preview",
        "org.alacritty", "io.alacritty", "com.apple.scripteditor2", "com.apple.automator",
        "org.python.pythonlauncher", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
        "dev.commandline.waveterm", "org.contourterminal.contour", "com.cool-retro-term",
    ]
    public static let refusedAppBundleIDPrefixes: [String] = ["com.apple.scripteditor.id.", "com.apple.automator."]
    public static let refusedAppNames: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "kitty", "wezterm", "warp", "alacritty", "script editor",
        "automator", "python launcher", "hyper", "tabby", "rio", "wave", "contour", "cool-retro-term",
    ]
    /// The `CFBundleExecutable` of an app saved from Script Editor ("applet", or "droplet" for
    /// one that takes dropped files) or Automator ("Application Stub", "Automator Application
    /// Stub"): it runs the script inside, whatever its bundle id.
    public static let refusedAppExecutables: Set<String> = [
        "applet", "droplet", "application stub", "automator application stub",
    ]

    /// `bundleID` or `name` (an app's display name, or its file name with or without ".app")
    /// is one of `refusedAppBundleIDs` / `refusedAppNames` or starts with one of
    /// `refusedAppBundleIDPrefixes`, or `executable` is one of `refusedAppExecutables`, in
    /// any case.
    public static func refusesApp(bundleID: String?, name: String?, executable: String? = nil) -> Bool {
        if let executable, refusedAppExecutables.contains(executable.lowercased()) { return true }
        if let bundleID = bundleID?.lowercased() {
            if refusedAppBundleIDs.contains(bundleID) { return true }
            if refusedAppBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        }
        guard var name = name?.lowercased() else { return false }
        if name.hasSuffix(".app") { name.removeLast(4) }
        return refusedAppNames.contains(name)
    }

    /// A stored "Open documents in" value (a bundle id or a path to an app).
    public static func refusesApp(id: String) -> Bool {
        id.hasPrefix("/") ? refusesApp(bundleID: nil, name: (id as NSString).lastPathComponent)
            : refusesApp(bundleID: id, name: nil)
    }

    public static func isOffice(_ type: UTType) -> Bool {
        officeIdentifiers.contains(type.identifier.lowercased())
    }
}
