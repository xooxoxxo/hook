import Darwin
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

    static func isOffice(_ type: UTType) -> Bool {
        officeIdentifiers.contains(type.identifier.lowercased())
    }
}

/// A document a click checked: what every opener uses, never the path the ask named.
public struct CheckedFile: Equatable, Sendable {
    /// The file the walk opened, by the path its descriptor reports (`F_GETPATH`): no
    /// symlink in it, every step checked.
    public let url: URL
    /// The type of that canonical name, by its extension (a folder as a package).
    public let type: UTType
    /// The device and inode the descriptor's `fstat` saw: right before anything opens the
    /// file, `FileAccess.isUnchanged` refuses it when the path now names something else.
    public let device: dev_t
    public let inode: ino_t
    /// The file's bytes, read from the checked descriptor when the caller asked (the viewer
    /// renders these and never opens the file by path again); nil otherwise, or when the
    /// file is larger than the limit (`tooLarge`). Any other failed read fails the check.
    public let contents: Data?
    /// The caller asked for the bytes and the file has more than the limit.
    public let tooLarge: Bool

    public init(url: URL, type: UTType, device: dev_t, inode: ino_t, contents: Data? = nil, tooLarge: Bool = false) {
        self.url = url
        self.type = type
        self.device = device
        self.inode = inode
        self.contents = contents
        self.tooLarge = tooLarge
    }
}

/// What a click found.
public enum FileCheck: Equatable, Sendable {
    /// A document on this Mac: the resolved file, which is what opens.
    case document(CheckedFile)
    /// There, but not a document type: only Reveal in Finder (the resolved file).
    case refused(URL)
    case missing
    /// Under a network root or a hidden root (/.vol, /.nofollow), a first folder that isn't
    /// plain ASCII, at a network mount, or on a network file system: never touched.
    case network
}

/// One entry of the kernel mount table.
public struct Mount: Equatable, Sendable {
    /// Where it is mounted (`f_mntonname`).
    public let path: String
    /// `f_fstypename`.
    public let type: String
    /// `MNT_LOCAL` is set.
    public let isLocal: Bool

    public init(path: String, type: String, isLocal: Bool) {
        self.path = path
        self.type = type
        self.isLocal = isLocal
    }
}

/// Paths as Hook uses them, and the click-time checks.
public enum FileAccess {
    /// Autofs and Finder network roots, as `Validator.networkForm` spells them: touching a
    /// path under one can reach a server.
    public static var networkRoots: [String] { Validator.networkRoots }
    /// The only file systems the walk enters: local disks (APFS, HFS+, FAT, exFAT) and /dev.
    /// Every other type (autofs, NFS, SMB, AFP, WebDAV, CIFS, FTP, macFUSE and other FUSE
    /// file systems, or one Hook doesn't know) counts as a network one.
    public static let localFileSystems: Set<String> = ["apfs", "hfs", "msdos", "exfat", "devfs"]

    /// `type` (an `f_fstypename`, in any case) is one of `localFileSystems`.
    public static func isLocalFileSystem(_ type: String) -> Bool {
        localFileSystems.contains(type.lowercased())
    }

    /// The lexical part of `NSString.standardizingPath`, without the filesystem: "//" and
    /// "." collapse, ".." drops the component before it (never above "/"), a trailing "/"
    /// goes. Expand "~" first.
    public static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// /net, /Network or /home (in any case, as the disk ignores case), also behind "//",
    /// /private, /private/var/automount, /var/automount or /System/Volumes/Data: the
    /// validator's N1 rule, with the prefixes stripped however they are stacked. Lexical.
    public static func isNetwork(_ path: String) -> Bool {
        path.hasPrefix("/") && Validator.isNetworkPath(path)
    }

    /// The first folder starts with "." (/.vol, /.nofollow, /.resolve): the validator's N2
    /// rule. Such roots reach files by id or skip the checks a path gets. Lexical.
    public static func isHiddenRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let first = path.split(separator: "/").first else { return false }
        return first.hasPrefix(".")
    }

    /// The first folder isn't plain ASCII: the validator's N3 rule (the disk's case folding
    /// turns "ſystem", "Syﬆem" or the Kelvin sign into ASCII names). Lexical.
    public static func isNonASCIIRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let first = path.unicodeScalars.split(separator: "/").first else { return false }
        return !first.allSatisfy(\.isASCII)
    }

    /// Never touched: a network path, a hidden root or a non-ASCII first folder. Lexical.
    public static func isUntouchable(_ path: String) -> Bool {
        isHiddenRoot(path) || isNonASCIIRoot(path) || isNetwork(path)
    }

    /// The type name `statfs` reports for the file system holding `folder` (nil when it
    /// can't be read).
    public static func fileSystemType(of folder: String) -> String? {
        var info = statfs()
        guard statfs(folder, &info) == 0 else { return nil }
        return cString(&info.f_fstypename)
    }

    /// The type name `fstatfs` reports for the file system holding an open descriptor.
    public static func fileSystemType(descriptor: Int32) -> String? {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { return nil }
        return cString(&info.f_fstypename)
    }

    /// The kernel mount table as it stands (`getmntinfo` with `MNT_NOWAIT`, in its
    /// thread-safe form, so no file system is asked); nil when it can't be read.
    public static func mountTable() -> [Mount]? {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return nil }
        defer { free(buffer) }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return Mount(path: cString(&entry.f_mntonname), type: cString(&entry.f_fstypename),
                         isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    /// A mount at exactly `path` (case-insensitively, with the /private and
    /// /System/Volumes/Data prefixes stripped from both, so /home matches the autofs mount
    /// at /System/Volumes/Data/home) that isn't a local disk: `MNT_LOCAL` clear, or a type
    /// outside `localFileSystems`.
    public static func isRemoteMount(at path: String, in mounts: [Mount]) -> Bool {
        let key = mountKey(path)
        return mounts.contains { mount in
            (!mount.isLocal || !isLocalFileSystem(mount.type)) && mountKey(mount.path) == key
        }
    }

    static func mountKey(_ path: String) -> String {
        Validator.networkForm(path).folding(options: [.caseInsensitive], locale: nil)
    }

    /// What the walk asks the system; tests pass their own. `mounts` is `mountTable()`, read
    /// before each step; `fileSystem` is the type of the file system an opened descriptor
    /// (at the given canonical path) is on.
    public struct Lookups {
        public var mounts: () -> [Mount]?
        public var fileSystem: (Int32, String) -> String?

        public init(mounts: @escaping () -> [Mount]? = { FileAccess.mountTable() },
                    fileSystem: @escaping (Int32, String) -> String? = { descriptor, _ in
                        FileAccess.fileSystemType(descriptor: descriptor)
                    }) {
            self.mounts = mounts
            self.fileSystem = fileSystem
        }

        public static var live: Lookups { Lookups() }
    }

    /// A click's checks: the path isn't untouchable (lexically, before and after
    /// `canonical`); then the walk (`walk`) opens it one component at a time from "/" and
    /// hands back a descriptor; that descriptor's `fstat` must show a regular file with no
    /// execute bit (or a folder, judged as a package), and the canonical name it reports,
    /// like the name asked for, must be a document type. Blocking: call it off the main
    /// actor. `readingUpTo` gives, for the resolved file, the most bytes to read from the
    /// same descriptor into `CheckedFile.contents` (nil: don't read).
    public static func check(_ path: String, readingUpTo limit: (URL) -> Int? = { _ in nil },
                             lookups: Lookups = .live) -> FileCheck {
        guard !isUntouchable(path) else { return .network }
        let lexical = canonical(path)
        guard lexical.hasPrefix("/"), !isUntouchable(lexical) else { return .network }
        switch walk(lexical, lookups: lookups) {
        case .missing: return .missing
        case .network: return .network
        case .special(let other): return .refused(URL(fileURLWithPath: other, isDirectory: false))
        case .opened(let descriptor, let resolved, let info):
            defer { close(descriptor) }
            let isFolder = info.st_mode & S_IFMT == S_IFDIR
            let url = URL(fileURLWithPath: resolved, isDirectory: isFolder)
            // A file anyone may run isn't opened as a document, whatever its name says.
            if !isFolder, info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 { return .refused(url) }
            let name = (resolved as NSString).lastPathComponent
            let type = isFolder
                ? UTType(filenameExtension: (name as NSString).pathExtension, conformingTo: .package) ?? .data
                : DocumentPolicy.type(fileName: name)
            guard DocumentPolicy.allows(fileName: lexical), DocumentPolicy.allows(type: type, fileName: resolved) else {
                return .refused(url)
            }
            var contents: Data?
            var tooLarge = false
            if let max = limit(url) {
                // Bytes the caller needs (the viewer), from the descriptor the checks ran on:
                // a read that fails for any reason but the size fails the click.
                guard !isFolder else { return .missing }
                switch read(descriptor: descriptor, size: info.st_size, upTo: max) {
                case .data(let data): contents = data
                case .tooLarge: tooLarge = true
                case .failed: return .missing
                }
            }
            return .document(CheckedFile(url: url, type: type, device: info.st_dev, inode: info.st_ino,
                                         contents: contents, tooLarge: tooLarge))
        }
    }

    /// The checked path still names the file the check saw: no symlink anywhere in it now
    /// (`AT_SYMLINK_NOFOLLOW_ANY`), and the same device and inode. Every opener asks right
    /// before it opens.
    public static func isUnchanged(_ file: CheckedFile) -> Bool {
        var info = stat()
        guard fstatat(AT_FDCWD, file.url.path(percentEncoded: false), &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
            return false
        }
        return info.st_mode & S_IFMT != S_IFLNK && info.st_dev == file.device && info.st_ino == file.inode
    }

    /// What `readFile` found.
    public enum ReadResult: Equatable, Sendable {
        case data(Data)
        /// A regular file with more than the limit.
        case tooLarge
        /// Not a regular file, a link, or unreadable.
        case failed
    }

    /// A regular file's bytes, at most `limit` of them; nil for anything `readFile` doesn't
    /// return as `.data`.
    public static func read(_ path: String, upTo limit: Int) -> Data? {
        if case .data(let data) = readFile(path, upTo: limit) { return data }
        return nil
    }

    /// The flags a read by path opens with: no symlink anywhere in the path (O_NOFOLLOW_ANY,
    /// which covers the last part too), no wait on a pipe or device (O_NONBLOCK), and the
    /// descriptor never reaches a child process.
    public static let readFlags = O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC
    /// The flags the walk opens a folder with (the last part may not be a link).
    public static let folderFlags = O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC
    /// The flags the walk opens the file with.
    public static let fileFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    /// A regular file's bytes, at most `limit` of them, through one descriptor opened with
    /// `readFlags`. With `identity` (the device and inode a check saw), the descriptor's
    /// `fstat` must match it, so the bytes are the checked file's.
    public static func readFile(_ path: String, upTo limit: Int, identity: (device: dev_t, inode: ino_t)? = nil) -> ReadResult {
        let descriptor = open(path, readFlags)
        guard descriptor >= 0 else { return .failed }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failed }
        if let identity, info.st_dev != identity.device || info.st_ino != identity.inode { return .failed }
        return read(descriptor: descriptor, size: info.st_size, upTo: limit)
    }

    /// At most `limit` bytes from an open regular file whose `fstat` gave `size`.
    static func read(descriptor: Int32, size: off_t, upTo limit: Int) -> ReadResult {
        guard size <= limit else { return .tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            // nil at the end of the file: an empty file.
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return data.count <= limit ? .data(data) : .tooLarge
        } catch {
            return .failed
        }
    }

    public enum Resolution: Equatable, Sendable {
        case path(String)
        case missing
        case network
    }

    /// The canonical path `walk` reaches, without keeping anything open.
    public static func resolve(_ path: String, lookups: Lookups = .live) -> Resolution {
        switch walk(path, lookups: lookups) {
        case .opened(let descriptor, let resolved, _):
            close(descriptor)
            return .path(resolved)
        case .special(let resolved): return .path(resolved)
        case .missing: return .missing
        case .network: return .network
        }
    }

    /// `resolve` with the file system type looked up by canonical path (tests).
    public static func resolve(_ path: String, fileSystem: @escaping (String) -> String?) -> Resolution {
        resolve(path, lookups: Lookups(fileSystem: { _, resolved in fileSystem(resolved) }))
    }

    /// What `walk` reached.
    public enum Walked {
        /// An open descriptor (the caller closes it) for a regular file or a folder, the
        /// canonical path it reports, and its `fstat`.
        case opened(Int32, String, stat)
        /// Something else (a pipe, a socket, a device): never opened.
        case special(String)
        case missing
        case network
    }

    /// `realpath` by descriptors. It opens "/" (`O_NOFOLLOW_ANY`), then for each component:
    /// the child's canonical path is the folder descriptor's `F_GETPATH` plus the component;
    /// before any call on the child, that path must not be untouchable and the mount table
    /// must have no network mount at it (`isRemoteMount`); then a folder opens with
    /// `folderFlags` relative to its parent, and a symlink is read (`readlinkat`) and its
    /// target walked in place of it, one hop at a time (at most 32), from "/" when it is
    /// absolute. Every descriptor's file system must be a local one. The last component, a
    /// regular file, opens with `fileFlags`; a pipe, socket or device is never opened.
    public static func walk(_ path: String, lookups: Lookups = .live) -> Walked {
        var pending = path.split(separator: "/").map(String.init)
        guard case .some(var folder) = openRoot(lookups) else { return localFailure(lookups) }
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            guard let here = descriptorPath(folder) else { close(folder); return .missing }
            let child = part == ".." ? (here as NSString).deletingLastPathComponent
                : (here == "/" ? "/" : here + "/") + part
            if isUntouchable(child) { close(folder); return .network }
            guard let mounts = lookups.mounts() else { close(folder); return .missing }
            if isRemoteMount(at: child, in: mounts) { close(folder); return .network }
            if part == ".." {
                let parent = openat(folder, "..", folderFlags)
                close(folder)
                guard parent >= 0 else { return .missing }
                if let failure = localCheck(parent, child, lookups) { close(parent); return failure }
                folder = parent
                continue
            }
            var info = stat()
            guard fstatat(folder, part, &info, AT_SYMLINK_NOFOLLOW) == 0 else { close(folder); return .missing }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                links += 1
                guard links <= 32, let target = readLink(folder, part), !target.isEmpty else {
                    close(folder)
                    return .missing
                }
                if target.hasPrefix("/") {
                    close(folder)
                    guard let root = openRoot(lookups) else { return localFailure(lookups) }
                    folder = root
                }
                pending = target.split(separator: "/").map(String.init) + pending
            case S_IFDIR:
                // Swapped for a link since the fstatat: O_NOFOLLOW refuses it.
                let next = openat(folder, part, folderFlags)
                close(folder)
                guard next >= 0 else { return .missing }
                if let failure = localCheck(next, child, lookups) { close(next); return failure }
                folder = next
            case S_IFREG:
                guard pending.allSatisfy({ $0 == "." }) else { close(folder); return .missing }
                let file = openat(folder, part, fileFlags)
                close(folder)
                guard file >= 0 else { return .missing }
                var opened = stat()
                guard fstat(file, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                      let resolved = descriptorPath(file) else { close(file); return .missing }
                if let failure = localCheck(file, resolved, lookups) { close(file); return failure }
                return .opened(file, resolved, opened)
            default:
                close(folder)
                return pending.isEmpty ? .special(child) : .missing
            }
        }
        var info = stat()
        guard fstat(folder, &info) == 0, let resolved = descriptorPath(folder) else { close(folder); return .missing }
        return .opened(folder, resolved, info)
    }

    /// "/" opened, its file system checked; nil on any failure.
    private static func openRoot(_ lookups: Lookups) -> Int32? {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard root >= 0 else { return nil }
        if localCheck(root, "/", lookups) != nil { close(root); return nil }
        return root
    }

    /// Why "/" failed to open: network when its file system isn't a local one.
    private static func localFailure(_ lookups: Lookups) -> Walked {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard root >= 0 else { return .missing }
        defer { close(root) }
        return localCheck(root, "/", lookups) ?? .missing
    }

    /// Nil when the descriptor is on a local file system; `.missing` when that can't be
    /// read, `.network` otherwise.
    private static func localCheck(_ descriptor: Int32, _ path: String, _ lookups: Lookups) -> Walked? {
        guard let type = lookups.fileSystem(descriptor, path) else { return .missing }
        return isLocalFileSystem(type) ? nil : .network
    }

    /// The path the kernel reports for an open descriptor (`F_GETPATH`).
    public static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A symlink's target, read relative to its folder's descriptor.
    static func readLink(_ folder: Int32, _ name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = readlinkat(folder, name, &buffer, Int(MAXPATHLEN))
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
