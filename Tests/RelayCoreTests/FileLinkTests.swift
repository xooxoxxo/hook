import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RelayCore

@Suite struct FileLinkTests {
    @Test func absoluteAndHomePathsAreKept() throws {
        let plain = try #require(FileLink("/Users/me/Documents/Plans/release-plan.md", home: "/Users/me"))
        #expect(plain.path == "/Users/me/Documents/Plans/release-plan.md")
        #expect(plain.name == "release-plan.md")
        #expect(plain.folder(home: "/Users/me") == "~/Documents/Plans")
        #expect(plain.viewerKind == .markdown)

        let home = try #require(FileLink("~/notes/todo.TXT", home: "/Users/me"))
        #expect(home.path == "/Users/me/notes/todo.TXT")
        #expect(home.raw == "~/notes/todo.TXT")
        #expect(home.url == URL(fileURLWithPath: "/Users/me/notes/todo.TXT"))
        #expect(home.viewerKind == .plain)
        #expect(FileLink("/tmp/report.pdf", home: "/Users/me")?.folder(home: "/Users/me") == "/tmp")
    }

    @Test(arguments: ["relative/path.md", "~other/x.md", "", "https://example.com/a.md", "/a\nb.md", "/a\u{7}.md"])
    func otherValuesAreNotFileLinks(_ raw: String) {
        #expect(FileLink(raw, home: "/Users/me") == nil)
    }

    @Test func viewerKindsByExtension() {
        #expect(DocumentKind(fileExtension: "md") == .markdown)
        #expect(DocumentKind(fileExtension: "Markdown") == .markdown)
        #expect(DocumentKind(fileExtension: "txt") == .plain)
        #expect(DocumentKind(fileExtension: "pdf") == nil)
        #expect(DocumentKind(fileExtension: "") == nil)
    }

    @Test func placeComparesTheAskHostWithThisMac() {
        #expect(FilePlace.of(askHost: nil, localHost: "build-mac", queueIsLocal: true) == .here)
        #expect(FilePlace.of(askHost: "  ", localHost: nil, queueIsLocal: true) == .here)
        // From a mailbox, a hostless ask may come from any machine.
        #expect(FilePlace.of(askHost: nil, localHost: "build-mac", queueIsLocal: false) == .otherMac(nil))
        #expect(FilePlace.of(askHost: " ", localHost: "build-mac", queueIsLocal: false) == .otherMac(nil))
        #expect(FilePlace.of(askHost: "Build-Mac.local", localHost: "build-mac", queueIsLocal: false) == .here)
        #expect(FilePlace.of(askHost: "studio-mac", localHost: "build-mac", queueIsLocal: true) == .otherMac("studio-mac"))
        // Not knowing this Mac's name can't prove the file is here.
        #expect(FilePlace.of(askHost: "studio-mac", localHost: nil, queueIsLocal: false) == .otherMac("studio-mac"))
    }

    @Test func pathsAreCanonicalWithoutTheDisk() throws {
        #expect(FileAccess.canonical("/a//b/./c.md") == "/a/b/c.md")
        #expect(FileAccess.canonical("/a/b/../c.md") == "/a/c.md")
        #expect(FileAccess.canonical("/../../etc/x.md") == "/etc/x.md")
        #expect(FileAccess.canonical("/a/..b/c.md") == "/a/..b/c.md")
        #expect(FileAccess.canonical("/var/tmp/") == "/var/tmp")
        let link = try #require(FileLink("~/../other/plan.md", home: "/Users/me"))
        #expect(link.path == "/Users/other/plan.md")
        #expect(link.raw == "~/../other/plan.md")
    }

    @Test(arguments: ["/net", "/net/host/share/doc.md", "/Network/Servers/x.md", "/NET/host/x.md",
                      "/private/net/host/x.md", "/private/var/automount/Network/x.md", "/var/automount/net/h/x",
                      "/network/x/a.md", "//net/h/a.md", "/System/Volumes/Data/home/u/a.md", "/home/u/a.md", "/HOME",
                      "/system/volumes/data/Network/x.md", "/private/private/net/h",
                      "/System/Volumes/Data/private/var/automount/net/h"])
    func networkPaths(_ path: String) {
        #expect(FileAccess.isNetwork(path))
        #expect(FileAccess.check(path) == .network)
    }

    @Test(arguments: ["/networks/x.md", "/netlify/x.md", "/Users/me/net/x.md", "/private/tmp/x.md",
                      "/homebrew/a.md", "/Users/x/.config/a.md"])
    func notNetworkPaths(_ path: String) {
        #expect(!FileAccess.isNetwork(path))
        #expect(!FileAccess.isUntouchable(path))
    }

    @Test(arguments: ["/.nofollow/Users/x/a.md", "/.vol/1/2", "/.resolve/1/2", "//.vol/1/2"])
    func hiddenRootsAreNeverTouched(_ path: String) throws {
        #expect(FileAccess.isHiddenRoot(path))
        #expect(FileAccess.check(path) == .network)
        let link = try #require(FileLink(path, home: "/Users/me"))
        #expect(FileRowState.of(place: .here, link: link) == .network)
    }

    @Test func aFolderOnANetworkFileSystemStopsTheWalk() throws {
        for name in ["apfs", "hfs", "msdos", "exfat", "devfs", "APFS"] {
            #expect(FileAccess.isLocalFileSystem(name), "\(name)")
        }
        for name in ["autofs", "nfs", "smbfs", "afpfs", "webdav", "cifs", "ftp", "macfuse", "osxfuse", "fusefs",
                     "unknown", "ntfs", "", "apfs2"] {
            #expect(!FileAccess.isLocalFileSystem(name), "\(name)")
        }
        // A local folder passes: statfs reads its type, and it isn't a network one.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("statfs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let type = try #require(FileAccess.fileSystemType(of: folder.path))
        #expect(!type.isEmpty)
        #expect(FileAccess.isLocalFileSystem(type))
        #expect(FileAccess.fileSystemType(of: "/") != nil)
        #expect(FileAccess.fileSystemType(of: folder.path + "/gone") == nil)
        // A folder reported as a network file system stops the walk before its child is touched.
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.md"))
        let real = try #require(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(FileAccess.resolve(folder.path + "/a.md") == .path(real + "/a.md"))
        var asked: [String] = []
        let mounted = FileAccess.resolve(folder.path + "/a.md") { path in
            asked.append(path)
            return path == real ? "smbfs" : FileAccess.fileSystemType(of: path)
        }
        #expect(mounted == .network)
        #expect(asked.last == real)
        #expect(FileAccess.resolve(folder.path + "/a.md") { _ in "AutoFS" } == .network)
        #expect(FileAccess.resolve(folder.path + "/a.md") { _ in nil } == .missing)
        // Any type that isn't a local disk stops the walk: FUSE, an unknown name, anything.
        for other in ["macfuse", "osxfuse", "fusefs", "unknown", "ntfs", "webdav", "cifs", "ftp", "nfs", "afpfs"] {
            let found = FileAccess.resolve(folder.path + "/a.md") { path in
                path == real ? other : FileAccess.fileSystemType(of: path)
            }
            #expect(found == .network, "\(other)")
        }
        for local in ["apfs", "hfs", "msdos", "exfat", "HFS"] {
            #expect(FileAccess.resolve(folder.path + "/a.md") { _ in local } == .path(real + "/a.md"), "\(local)")
        }
        // /net is an autofs mount on macOS: the walk stops at it by type as well as by name.
        if let net = FileAccess.fileSystemType(of: "/net") { #expect(net == "autofs") }
    }

    @Test(arguments: ["plan.md", "notes.markdown", "a.txt", "data.csv", "c.json", "c.yaml", "c.yml", "r.pdf",
                      "p.png", "p.jpg", "p.jpeg", "s.heic", "g.gif", "t.tif", "t.tiff", "a.mp3", "v.mp4", "m.mov",
                      "k.key", "p.pages", "n.numbers", "d.docx", "x.xlsx", "p.pptx", "d.doc", "x.xls", "p.ppt",
                      "app.log", "a.m4a"])
    func documentTypesOpen(_ name: String) {
        #expect(DocumentPolicy.allows(fileName: "/Users/me/" + name))
    }

    /// The identifiers macOS really reports for .log and .m4a (com.apple.log and
    /// com.apple.m4a-audio), checked on real files.
    @Test func logsAndM4AOpenOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("types-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, identifier) in [("app.log", "com.apple.log"), ("voice.m4a", "com.apple.m4a-audio")] {
            let file = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            let checked = try #require(FileAccess.check(file.path).checked, "\(name)")
            #expect(checked.type.identifier == identifier, "\(name)")
            #expect(try file.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier == identifier, "\(name)")
        }
    }

    /// Every listed identifier opens, by exact identifier.
    @Test func everyListedTypeOpens() throws {
        let listed = DocumentPolicy.allowedIdentifiers.union(DocumentPolicy.officeIdentifiers)
        #expect(listed.count == 18 + 14)
        for identifier in listed {
            let type = try #require(UTType(identifier), "\(identifier)")
            #expect(DocumentPolicy.allows(type: type, fileName: "/Users/me/x"), "\(identifier)")
        }
    }

    /// Not on the list, so refused, even where the type conforms to text, an image, audio
    /// or a spreadsheet.
    @Test(arguments: ["w.xlw", "t.xltx", "t.potx", "p.odp", "c.ics", "v.vcf", "i.svg", "page.html", "r.rtf",
                      "i.webp", "i.heif", "s.wav", "a.aac", "v.m4v", "n.rtfd", "o.odt",
                      "o.ods", "e.eml", "s.swift", "m.plist"])
    func unlistedTypesAreRefused(_ name: String) {
        #expect(!DocumentPolicy.allows(fileName: "/Users/me/" + name))
    }

    @Test(arguments: ["Tool.app", "setup.pkg", "disk.dmg", "run.sh", "run.command", "x.tool", "x.terminal",
                      "a.webloc", "a.inetloc", "a.fileloc", "w.workflow", "s.scpt", "s.applescript", "a.action",
                      "p.prefpane", "k.kext", "p.plugin", "m.mobileconfig", "page.html", "page.htm", "p.xhtml",
                      "i.svg", "f.xml", "s.py", "s.js", "s.rb", "w.exe", "l.dll", "a.zip", "u.url", "README",
                      "a.jar", "i.msi"])
    func otherTypesAreRefused(_ name: String) {
        #expect(!DocumentPolicy.allows(fileName: "/Users/me/" + name))
    }

    @Test(arguments: ["d.doc", "d.docx", "x.xls", "x.xlsx", "p.ppt", "p.pptx", "s.pps", "s.ppsx",
                      "p.pages", "n.numbers", "k.key"])
    func officeDocumentsOpen(_ name: String) {
        #expect(DocumentPolicy.allows(fileName: "/Users/me/" + name))
    }

    @Test(arguments: ["a.xla", "a.xll", "a.xlam", "a.ppam", "t.dotm", "b.xlsb", "t.xlt", "t.pot",
                      "m.docm", "m.xlsm", "m.pptm", "m.ppsm", "m.xltm", "m.potm", "t.dot", "t.dotx"])
    func officeAddInsMacrosAndTemplatesAreRefused(_ name: String) {
        #expect(!DocumentPolicy.allows(fileName: "/Users/me/" + name))
    }

    @Test func officeIsAnExplicitList() throws {
        // Identifiers, not prefixes: another Microsoft or Open XML type isn't a document.
        #expect(DocumentPolicy.isOffice(try #require(UTType("com.microsoft.word.doc"))))
        #expect(DocumentPolicy.isOffice(try #require(UTType("com.apple.iwork.pages.pages"))))
        #expect(!DocumentPolicy.isOffice(try #require(UTType("org.openxmlformats.openxml"))))
        #expect(!DocumentPolicy.isOffice(try #require(UTType("com.microsoft.excel.xla"))))
        // A type whose identifier says macros or add-in is refused, whatever it conforms to.
        let macro = UTType(exportedAs: "com.example.sheet.macroenabled", conformingTo: .spreadsheet)
        #expect(!DocumentPolicy.allows(type: macro, fileName: "/Users/me/a.sheet"))
        let addIn = UTType(exportedAs: "com.example.addin", conformingTo: .presentation)
        #expect(!DocumentPolicy.allows(type: addIn, fileName: "/Users/me/a.deck"))
        // Conformance alone opens nothing: an exact identifier is needed.
        let plain = UTType(exportedAs: "com.example.sheet", conformingTo: .spreadsheet)
        #expect(!DocumentPolicy.allows(type: plain, fileName: "/Users/me/a.sheet"))
        #expect(!DocumentPolicy.allows(type: .spreadsheet, fileName: "/Users/me/a.sheet"))
        #expect(!DocumentPolicy.allows(type: .text, fileName: "/Users/me/a.txt"))
        #expect(!DocumentPolicy.allows(type: .image, fileName: "/Users/me/a.png"))
    }

    @Test func clickChecksTheFileOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("filecheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: doc)
        let script = folder.appendingPathComponent("run.sh")
        try Data("echo".utf8).write(to: script)
        // A folder named like a document, and a link named like one pointing at a script.
        let folderDoc = folder.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: folderDoc, withIntermediateDirectories: false)
        let disguised = folder.appendingPathComponent("notes.md")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: script)
        let toNet = folder.appendingPathComponent("remote.md")
        try FileManager.default.createSymbolicLink(atPath: toNet.path, withDestinationPath: "/net/example-host/doc.md")

        // The temporary folder sits behind the /var → /private/var link.
        let real = try #require(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(FileAccess.check(doc.path).checked?.url == URL(fileURLWithPath: real + "/plan.md"))
        #expect(FileAccess.check(folder.path + "/./sub/../plan.md").checked?.url == URL(fileURLWithPath: real + "/plan.md"))
        #expect(FileAccess.check(script.path) == .refused(URL(fileURLWithPath: real + "/run.sh")))
        #expect(FileAccess.check(folderDoc.path) == .refused(URL(fileURLWithPath: real + "/folder.md")))
        #expect(FileAccess.check(disguised.path) == .refused(URL(fileURLWithPath: real + "/run.sh")))
        #expect(FileAccess.check(toNet.path) == .network)
        #expect(FileAccess.check(folder.path + "/gone.md") == .missing)
    }

    /// The opener gets what the check resolved and read: the real file, its type, and (when
    /// asked) its bytes, read once right after the check through a descriptor that won't
    /// follow a link or wait on a pipe.
    @Test func theCheckHandsOverWhatItChecked() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("checked-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = try #require(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let doc = folder.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: doc)
        let alias = folder.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: doc)
        let empty = folder.appendingPathComponent("empty.txt")
        try Data().write(to: empty)

        let plain = try #require(FileAccess.check(alias.path).checked)
        #expect(plain.url == URL(fileURLWithPath: real + "/plan.md"))
        #expect(plain.type.conforms(to: .text))
        #expect(plain.contents == nil)

        var asked: [URL] = []
        let read = try #require(FileAccess.check(alias.path, readingUpTo: { asked.append($0); return 100 }).checked)
        #expect(asked == [URL(fileURLWithPath: real + "/plan.md")])
        #expect(read.contents == Data("# Plan".utf8))
        #expect(FileAccess.check(doc.path, readingUpTo: { _ in 3 }).checked?.contents == nil)
        #expect(FileAccess.check(empty.path, readingUpTo: { _ in 10 }).checked?.contents == Data())

        // The reader itself: a link or a pipe gives nothing, and a pipe doesn't block.
        #expect(FileAccess.read(real + "/plan.md", upTo: 100) == Data("# Plan".utf8))
        #expect(FileAccess.read(alias.path, upTo: 100) == nil)
        let pipe = folder.appendingPathComponent("pipe.md").path
        #expect(mkfifo(pipe, 0o600) == 0)
        #expect(FileAccess.read(pipe, upTo: 100) == nil)
    }

    /// The viewer's read: a file too large is marked so, and any other failed read fails
    /// the check, so nothing opens in its place.
    @Test func aFailedReadFailsTheCheck() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readfail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: doc)
        let big = try #require(FileAccess.check(doc.path, readingUpTo: { _ in 3 }).checked)
        #expect(big.contents == nil && big.tooLarge)
        #expect(FileAccess.check(doc.path).checked?.tooLarge == false)
        #expect(FileAccess.readFile(big.url.path, upTo: 3) == .tooLarge)
        #expect(FileAccess.readFile(big.url.deletingLastPathComponent().path, upTo: 3) == .failed)

        let locked = folder.appendingPathComponent("locked.md")
        try Data("secret".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o200) == 0)
        defer { chmod(locked.path, 0o600) }
        // The check opens the file it checks, so a file Hook can't read opens nowhere.
        #expect(FileAccess.check(locked.path) == .missing)
        #expect(FileAccess.check(locked.path, readingUpTo: { _ in 100 }) == .missing)
    }

    /// Between the check and the open, the file is swapped: for a symlink (to another
    /// document, even), or for a new file at the same path. Either way the path no longer
    /// names what was checked.
    @Test func aSwapAfterTheCheckIsCaught() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appendingPathComponent("plan.md")
        let other = folder.appendingPathComponent("other.md")
        try Data("# Plan".utf8).write(to: doc)
        try Data("# Other".utf8).write(to: other)

        let checked = try #require(FileAccess.check(doc.path).checked)
        #expect(checked.inode != 0)
        #expect(FileAccess.isUnchanged(checked))
        try Data("# Plan, edited in place".utf8).write(to: doc, options: [])
        #expect(FileAccess.isUnchanged(checked))

        let before = try #require(FileAccess.check(doc.path).checked)
        try FileManager.default.removeItem(at: doc)
        try FileManager.default.createSymbolicLink(at: doc, withDestinationURL: other)
        #expect(!FileAccess.isUnchanged(before))

        try FileManager.default.removeItem(at: doc)
        try Data("# Replaced".utf8).write(to: doc)
        #expect(!FileAccess.isUnchanged(before))
        try FileManager.default.removeItem(at: doc)
        #expect(!FileAccess.isUnchanged(before))
    }

    /// Reads never follow a symlink anywhere in the path (a linked folder too), and the
    /// check's read must land on the inode the check saw.
    @Test func readsRefuseALinkedFolderAndAnotherInode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nofollow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = try #require(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let inner = real + "/inner"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: false)
        try Data("# Plan".utf8).write(to: URL(fileURLWithPath: inner + "/plan.md"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: inner + "/shot.png"))
        try FileManager.default.createSymbolicLink(atPath: real + "/linked", withDestinationPath: inner)

        #expect(FileAccess.readFlags & O_NOFOLLOW_ANY != 0)
        #expect(FileAccess.readFlags & O_NOFOLLOW == 0)
        #expect(FileAccess.read(inner + "/plan.md", upTo: 100) == Data("# Plan".utf8))
        #expect(FileAccess.read(real + "/linked/plan.md", upTo: 100) == nil)
        #expect(FileAccess.read(real + "/linked/shot.png", upTo: 100) == nil)
        // The temporary folder's own path goes through /var → /private/var: a link.
        #expect(FileAccess.read(folder.path + "/inner/plan.md", upTo: 100) == nil || folder.path == real)

        // The check resolves the linked folder first, then reads the real file.
        let checked = try #require(FileAccess.check(real + "/linked/plan.md", readingUpTo: { _ in 100 }).checked)
        #expect(checked.url == URL(fileURLWithPath: inner + "/plan.md"))
        #expect(checked.contents == Data("# Plan".utf8))
        let identity = (device: checked.device, inode: checked.inode)
        #expect(FileAccess.readFile(inner + "/plan.md", upTo: 100, identity: identity) == .data(Data("# Plan".utf8)))
        #expect(FileAccess.readFile(inner + "/plan.md", upTo: 100, identity: (checked.device, checked.inode + 1)) == .failed)
        #expect(FileAccess.readFile(inner + "/shot.png", upTo: 100, identity: identity) == .failed)
    }

    @Test func rowStates() throws {
        let doc = try #require(FileLink("/Users/me/plan.md", home: "/Users/me"))
        let script = try #require(FileLink("/Users/me/run.command", home: "/Users/me"))
        let remote = try #require(FileLink("/Network/Servers/x.md", home: "/Users/me"))
        #expect(FileRowState.of(place: .here, link: doc) == .available)
        #expect(FileRowState.of(place: .here, link: script) == .refused)
        #expect(FileRowState.of(place: .here, link: remote) == .network)
        #expect(FileRowState.of(place: .otherMac("studio-mac"), link: script) == .otherMac("studio-mac"))
        #expect(FileRowState.after(.document(CheckedFile(url: doc.url, type: .text, device: 1, inode: 2))) == nil)
        #expect(FileRowState.after(.missing) == .missing)
        #expect(FileRowState.after(.refused(doc.url)) == .refused)
        #expect(FileRowState.after(.network) == .network)
        #expect(FileRowState.available.note == nil)
        #expect(FileRowState.missing.note == "File not found")
        #expect(FileRowState.refused.note == "Hook doesn't open this kind of file")
        #expect(FileRowState.otherMac("studio\u{202E}mac").note == "On studio⟨U+202E⟩mac")
        #expect(FileRowState.otherMac(nil).note == "From another machine")
        #expect(FileRowState.available.canOpen && FileRowState.available.canReveal)
        #expect(!FileRowState.refused.canOpen && FileRowState.refused.canReveal)
        #expect(!FileRowState.missing.canOpen && !FileRowState.missing.canReveal)
        #expect(!FileRowState.network.canReveal && !FileRowState.otherMac("x").canReveal)
    }

    @Test func documentTargetReadsTheSetting() {
        #expect(DocumentTarget(config: nil) == .viewer)
        #expect(DocumentTarget(config: " ") == .viewer)
        #expect(DocumentTarget(config: "hook") == .viewer)
        #expect(DocumentTarget(config: "system") == .systemDefault)
        #expect(DocumentTarget(config: " com.example.writer ") == .app("com.example.writer"))
        #expect(DocumentTarget(config: "com.example-co.Writer2") == .app("com.example-co.Writer2"))
        // Neither a bundle id nor an absolute path.
        #expect(DocumentTarget(config: "Writer") == .viewer)
        #expect(DocumentTarget(config: "Applications/Writer.app") == .viewer)
        #expect(DocumentTarget(config: "com..example") == .viewer)
        #expect(DocumentTarget(config: "com.example writer") == .viewer)
        #expect(DocumentTarget(config: "/Applications/Writer.app").configValue == "/Applications/Writer.app")
    }

    /// Terminals and script runners are never where documents open.
    @Test func appsThatRunWhatTheyOpenAreRefused() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                   "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.alacritty", "com.apple.ScriptEditor2",
                   "com.apple.Automator", "org.python.PythonLauncher", "co.zeit.hyper", "org.tabby",
                   "com.raphaelamorim.rio", "dev.commandline.waveterm", "org.contourterminal.Contour",
                   "com.cool-retro-term", "com.apple.ScriptEditor.id.My-Applet", "com.apple.automator.My-Flow"] {
            #expect(DocumentPolicy.refusesApp(bundleID: id, name: nil), "\(id)")
            #expect(DocumentTarget(config: id) == .viewer, "\(id)")
            #expect(DocumentChoice.options(current: id, appName: "X").map(\.id) == ["hook", "system", DocumentChoice.otherID])
        }
        for name in ["Terminal.app", "iTerm.app", "Ghostty", "kitty.app", "WezTerm", "Warp.app", "Alacritty",
                     "Script Editor.app", "Automator", "Python Launcher.app", "Python Launcher", "Hyper.app",
                     "Hyper", "Tabby.app", "tabby", "Rio.app", "Wave.app", "Contour.app", "cool-retro-term.app"] {
            #expect(DocumentPolicy.refusesApp(bundleID: nil, name: name), "\(name)")
        }
        #expect(DocumentTarget(config: "/System/Applications/Utilities/Terminal.app") == .viewer)
        #expect(DocumentTarget(config: "/Applications/iTerm.app") == .viewer)
        #expect(DocumentTarget(config: "/Applications/Python 3.13/Python Launcher.app") == .viewer)
        #expect(DocumentTarget(config: "/Applications/Hyper.app") == .viewer)
        #expect(DocumentTarget(config: "/Applications/Tabby.app") == .viewer)
        #expect(!DocumentPolicy.refusesApp(bundleID: "com.apple.TextEdit", name: "TextEdit.app"))
        #expect(!DocumentPolicy.refusesApp(bundleID: nil, name: "Terminally Fine.app"))
        for executable in ["applet", "Application Stub", "APPLET", "droplet", "Droplet", "Automator Application Stub"] {
            #expect(DocumentPolicy.refusesApp(bundleID: "com.example.x", name: "X.app", executable: executable))
        }
        #expect(!DocumentPolicy.refusesApp(bundleID: "com.example.x", name: "X.app", executable: "X"))
        #expect(!DocumentPolicy.refusesApp(bundleID: "com.apple.ScriptEditor.idle", name: nil))
        #expect(!DocumentPolicy.refusesApp(bundleID: "com.apple.automatorx", name: nil))
        #expect(DocumentTarget(config: "com.apple.ScriptEditor.id.My-Applet") == .viewer)
        #expect(DocumentTarget(config: "/Applications/Rio.app") == .viewer)
        #expect(DocumentTarget(config: "com.apple.TextEdit") == .app("com.apple.TextEdit"))
    }

    /// A file with an execute bit opens as nothing, whatever its name; a folder (a package
    /// such as a Pages document) is judged by its type.
    @Test func anExecutableFileIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("exec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: doc)
        #expect(FileAccess.check(doc.path).checked != nil)
        for mode in [0o744, 0o654, 0o645, 0o755] {
            #expect(chmod(doc.path, mode_t(mode)) == 0)
            guard case .refused = FileAccess.check(doc.path) else {
                Issue.record("mode \(String(mode, radix: 8)) wasn't refused"); continue
            }
        }
        #expect(chmod(doc.path, 0o644) == 0)
        #expect(FileAccess.check(doc.path).checked != nil)
    }

    @Test func routes() {
        #expect(DocumentTarget.viewer.route(.markdown) == .viewer)
        #expect(DocumentTarget.viewer.route(.plain) == .viewer)
        #expect(DocumentTarget.viewer.route(nil) == .defaultApp)
        #expect(DocumentTarget.systemDefault.route(.markdown) == .defaultApp)
        #expect(DocumentTarget.app("com.example.writer").route(nil) == .app("com.example.writer"))
    }

    @Test func pickerOptions() {
        let plain = DocumentChoice.options(current: nil, appName: nil)
        #expect(plain.map(\.id) == ["hook", "system", DocumentChoice.otherID])
        let chosen = DocumentChoice.options(current: "com.example.writer", appName: "Writer")
        #expect(chosen.map(\.title) == ["Hook's viewer", "The file's default app", "Writer", "Other App…"])
        #expect(chosen[2].id == "com.example.writer")
        #expect(DocumentChoice.options(current: "com.example.gone", appName: nil)[2].title == "com.example.gone")
    }

    @Test(arguments: [
        ("{}", "hook"), (#"{"openDocumentsIn":"system"}"#, "system"),
        (#"{"openDocumentsIn":" com.example.writer "}"#, "com.example.writer"),
        (#"{"openDocumentsIn":""}"#, "hook"), (#"{"openDocumentsIn":3}"#, "hook"),
    ])
    func settingDecodesLeniently(_ json: String, _ expected: String) throws {
        #expect(try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8)).openDocumentsIn == expected)
    }
}

@Suite struct DetailTextTests {
    @Test func inlineStylesAndLineBreaks() {
        let text = DetailText.attributed("Check the **dates** and *rollback*, `beta` too.\nSecond line.")
        #expect(String(text.characters) == "Check the dates and rollback, beta too.\nSecond line.")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.code))
    }

    @Test func onlyWebLinksStayLinks() {
        let text = DetailText.attributed(
            "[tracker](https://tracker.example.com/42) [file](file:///etc/hosts) [x](javascript:alert(1)) [r](relay://open)")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://tracker.example.com/42")!])
        #expect(String(text.characters).contains("file"))
    }

    @Test func linkHelpNamesEveryAddress() {
        let text = DetailText.attributed("[tracker](https://tracker.example.com/42) and [docs](http://docs.example.com/a) "
                                         + "[again](https://tracker.example.com/42) [x](mailto:a@example.com)")
        #expect(DetailText.linkHelp(text) == "https://tracker.example.com/42\nhttp://docs.example.com/a")
        #expect(DetailText.linkHelp(DetailText.attributed("no links")) == "")
    }

    @Test func hiddenCharactersAreRevealed() {
        #expect(String(DetailText.attributed("a\u{202E}b").characters) == "a⟨U+202E⟩b")
    }

    @Test func blockSyntaxStaysAsTyped() {
        #expect(String(DetailText.attributed("1. one\n2. two").characters) == "1. one\n2. two")
    }
}

extension FileCheck {
    /// The checked file of a `.document` result.
    var checked: CheckedFile? {
        if case .document(let file) = self { return file }
        return nil
    }
}
