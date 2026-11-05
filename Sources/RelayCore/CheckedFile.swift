import Darwin
import Foundation
import UniformTypeIdentifiers

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
