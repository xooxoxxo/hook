import Foundation
import RelayCore

/// `~/.local/state/relay/away`, present only while Hook says the owner is away,
/// so other tools can tell (ssh's `Match exec "test -e …"`, for example).
/// Two lines: `since=<ISO 8601 UTC>` and `reason=<reason>`.
public struct AwayFlag: Sendable {
    public let directory: URL

    public var file: URL { directory.appending(path: "away") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/.local/state/relay`.
    public static var standard: AwayFlag {
        AwayFlag(directory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: ".local/state/relay", directoryHint: .isDirectory))
    }

    /// The file's contents.
    public static func contents(reason: String, since: Date) -> String {
        let line = reason.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "since=\(since.formatted(.iso8601))\nreason=\(line)\n"
    }

    /// A regular file at the path; a symlink doesn't count.
    public var isSet: Bool {
        var info = stat()
        return lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Writes the flag atomically through `PrivateFile.write` in a 0700 directory.
    /// A symlink at the file's path is refused, never followed or replaced.
    @discardableResult
    public func set(reason: String, since: Date) -> Result<Void, any Error> {
        Result {
            try PrivateFile.ensureDirectory(directory)
            var info = stat()
            if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw PrivateFile.TrustError.untrustedFile("\(file.path) is a symlink; refusing to use it")
            }
            try PrivateFile.write(Data(Self.contents(reason: reason, since: since).utf8), to: file)
        }
    }

    /// Removes the file (`unlink` never follows a symlink). Already gone is success.
    @discardableResult
    public func clear() -> Result<Void, any Error> {
        guard unlink(file.path) != 0, errno != ENOENT else { return .success(()) }
        return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }
}
