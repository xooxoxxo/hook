import Darwin
import Foundation
import Testing
@testable import RelayCore

/// The descriptor walk: every step opens relative to the folder before it, a mount that
/// isn't a local disk stops the walk before anything touches its path, and what the check
/// hands over is the inode it opened.
@Suite struct FileWalkTests {
    /// A temporary folder by its real path (no /var → /private/var link), removed after.
    struct Folder {
        let real: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("walk-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            real = try #require(realpath(url.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
        }
        func write(_ relative: String, _ text: String) throws {
            let url = URL(fileURLWithPath: real + "/" + relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func remove() { try? FileManager.default.removeItem(atPath: real) }
    }

    @Test func theWalkOpensFoldersWithoutFollowingAndTheFileWithoutBlocking() {
        #expect(FileAccess.folderFlags & O_NOFOLLOW != 0 && FileAccess.folderFlags & O_DIRECTORY != 0)
        #expect(FileAccess.folderFlags & O_CLOEXEC != 0)
        #expect(FileAccess.fileFlags & O_NOFOLLOW != 0 && FileAccess.fileFlags & O_NONBLOCK != 0)
        #expect(FileAccess.fileFlags & O_CLOEXEC != 0 && FileAccess.fileFlags & O_ACCMODE == O_RDONLY)
    }

    /// The canonical path is the one the descriptor reports: links resolved, relative and
    /// absolute, through ".." too.
    @Test func linksResolveOneHopAtATime() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("a/b/plan.md", "# Plan")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: folder.real + "/rel", withDestinationPath: "a/b")
        try fm.createSymbolicLink(atPath: folder.real + "/up", withDestinationPath: "a/b/../b")
        try fm.createSymbolicLink(atPath: folder.real + "/abs", withDestinationPath: folder.real + "/a")
        try fm.createSymbolicLink(atPath: folder.real + "/loop", withDestinationPath: "loop")
        let want = URL(fileURLWithPath: folder.real + "/a/b/plan.md", isDirectory: false)
        #expect(FileAccess.check(folder.real + "/rel/plan.md").checked?.url == want)
        #expect(FileAccess.check(folder.real + "/up/plan.md").checked?.url == want)
        #expect(FileAccess.check(folder.real + "/abs/b/plan.md").checked?.url == want)
        #expect(FileAccess.check(folder.real + "/loop/plan.md") == .missing)
        #expect(FileAccess.resolve(folder.real + "/rel") == .path(folder.real + "/a/b"))
        // A file in the middle of a path isn't a folder.
        #expect(FileAccess.check(folder.real + "/a/b/plan.md/x.md") == .missing)
    }

    /// A pipe named like a document is refused without being opened (it would block).
    @Test func aPipeIsNeverOpened() throws {
        let folder = try Folder()
        defer { folder.remove() }
        #expect(mkfifo(folder.real + "/pipe.md", 0o600) == 0)
        #expect(FileAccess.check(folder.real + "/pipe.md", readingUpTo: { _ in 100 })
            == .refused(URL(fileURLWithPath: folder.real + "/pipe.md", isDirectory: false)))
    }

    /// The type comes from the canonical name, by extension.
    @Test func theTypeIsTheCanonicalName() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("notes.txt", "plain")
        try FileManager.default.createSymbolicLink(atPath: folder.real + "/alias.md", withDestinationPath: "notes.txt")
        let checked = try #require(FileAccess.check(folder.real + "/alias.md").checked)
        #expect(checked.type.identifier == "public.plain-text")
    }

    /// After the walk, the folder is swapped for a link to another folder holding a file of
    /// the same name: the opener's re-check refuses the path, and the bytes are still the
    /// checked file's.
    @Test func aFolderSwappedForALinkAfterTheWalkIsRefused() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("inner/plan.md", "# Plan")
        try folder.write("elsewhere/plan.md", "# Other")
        let checked = try #require(FileAccess.check(folder.real + "/inner/plan.md", readingUpTo: { _ in 100 }).checked)
        #expect(FileAccess.isUnchanged(checked))
        try FileManager.default.moveItem(atPath: folder.real + "/inner", toPath: folder.real + "/inner-old")
        try FileManager.default.createSymbolicLink(atPath: folder.real + "/inner", withDestinationPath: folder.real + "/elsewhere")
        #expect(!FileAccess.isUnchanged(checked))
        #expect(checked.contents == Data("# Plan".utf8))
    }

    /// During the walk, right after the folder opens, it is swapped for a link: the walk
    /// goes on from the descriptor it holds, so it reaches the inode it checked, by the
    /// path that inode has now.
    @Test func aFolderSwappedDuringTheWalkYieldsTheCheckedInode() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("inner/plan.md", "# Plan")
        try folder.write("elsewhere/plan.md", "# Other")
        var original = stat()
        #expect(stat(folder.real + "/inner/plan.md", &original) == 0)
        var swapped = false
        let lookups = FileAccess.Lookups(fileSystem: { descriptor, path in
            if path == folder.real + "/inner", !swapped {
                swapped = true
                try? FileManager.default.moveItem(atPath: folder.real + "/inner", toPath: folder.real + "/inner-old")
                try? FileManager.default.createSymbolicLink(atPath: folder.real + "/inner",
                                                            withDestinationPath: folder.real + "/elsewhere")
            }
            return FileAccess.fileSystemType(descriptor: descriptor)
        })
        let checked = try #require(FileAccess.check(folder.real + "/inner/plan.md", readingUpTo: { _ in 100 },
                                                    lookups: lookups).checked)
        #expect(swapped)
        #expect(checked.inode == original.st_ino && checked.device == original.st_dev)
        #expect(checked.contents == Data("# Plan".utf8))
        #expect(checked.url.path(percentEncoded: false) == folder.real + "/inner-old/plan.md")
        #expect(FileAccess.isUnchanged(checked))
    }

    /// A mount table entry at a step that isn't a local disk stops the walk before anything
    /// touches that path: the folder needn't even exist, and its file system is never asked.
    @Test(arguments: [
        Mount(path: "share", type: "smbfs", isLocal: false),
        Mount(path: "share", type: "autofs", isLocal: false),
        Mount(path: "share", type: "macfuse", isLocal: true),
        Mount(path: "share", type: "apfs", isLocal: false),
        Mount(path: "SHARE", type: "nfs", isLocal: false),
    ])
    func aNetworkMountStopsTheWalkBeforeItsPath(_ fake: Mount) throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("share/a.md", "x")
        let mount = Mount(path: folder.real + "/" + fake.path, type: fake.type, isLocal: fake.isLocal)
        var asked: [String] = []
        let lookups = FileAccess.Lookups(
            mounts: { (FileAccess.mountTable() ?? []) + [mount] },
            fileSystem: { descriptor, path in
                asked.append(path)
                return FileAccess.fileSystemType(descriptor: descriptor)
            })
        #expect(FileAccess.check(folder.real + "/share/a.md", lookups: lookups) == .network)
        #expect(FileAccess.check(folder.real + "/share/gone/a.md", lookups: lookups) == .network)
        #expect(!asked.contains { $0.lowercased().hasPrefix(folder.real.lowercased() + "/share") })
        #expect(asked.last == folder.real)
        #expect(FileAccess.resolve(folder.real + "/share", lookups: lookups) == .network)
    }

    /// The same mount spelled behind /System/Volumes/Data (as /home's autofs mount is) or
    /// without /private matches; a local disk mounted there doesn't stop anything, and an
    /// unreadable mount table fails the walk.
    @Test func mountsMatchEverySpellingAndLocalOnesPass() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try folder.write("share/a.md", "x")
        func check(_ mount: Mount) -> FileCheck {
            FileAccess.check(folder.real + "/share/a.md",
                             lookups: FileAccess.Lookups(mounts: { (FileAccess.mountTable() ?? []) + [mount] }))
        }
        #expect(check(Mount(path: "/System/Volumes/Data" + folder.real + "/share", type: "smbfs", isLocal: false)) == .network)
        if folder.real.hasPrefix("/private/") {
            #expect(check(Mount(path: String(folder.real.dropFirst(8)) + "/share", type: "webdav", isLocal: false)) == .network)
        }
        #expect(check(Mount(path: folder.real + "/share", type: "apfs", isLocal: true)).checked != nil)
        #expect(check(Mount(path: folder.real + "/shared", type: "smbfs", isLocal: false)).checked != nil)
        #expect(FileAccess.check(folder.real + "/share/a.md", lookups: FileAccess.Lookups(mounts: { nil })) == .missing)
        #expect(FileAccess.isRemoteMount(at: "/home", in: [Mount(path: "/System/Volumes/Data/home", type: "autofs", isLocal: false)]))
        #expect(!FileAccess.isRemoteMount(at: "/", in: FileAccess.mountTable() ?? []))
    }

    /// The real mount table reads, and holds "/" as a local disk.
    @Test func theMountTableReads() throws {
        let mounts = try #require(FileAccess.mountTable())
        let root = try #require(mounts.first { $0.path == "/" })
        #expect(root.isLocal && FileAccess.isLocalFileSystem(root.type))
    }

    /// N3 on the click side: a non-ASCII first folder is never touched.
    @Test(arguments: ["/\u{17F}ystem/Volumes/Data/home/u/a.md", "/Sy\u{FB06}em/Volumes/Data/net/h/a.md", "/\u{212A}ext/a.md"])
    func aNonASCIIFirstFolderIsNeverTouched(_ path: String) {
        #expect(FileAccess.isUntouchable(path))
        #expect(FileAccess.check(path) == .network)
    }

    @Test func aNonASCIIFolderFurtherDownIsFine() {
        #expect(!FileAccess.isUntouchable("/Users/Jos\u{E9}/a.md"))
    }
}
