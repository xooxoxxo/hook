import Foundation

/// Private files: directories are 0700, and a file is created
/// 0600 from the start (never written first and restricted afterwards).
public enum PrivateFile {
    /// A folder or file Relay refuses to use; the description is the user-facing message.
    public enum TrustError: Error, Sendable, Equatable, LocalizedError {
        case untrustedDirectory(String)
        case untrustedFile(String)

        public var errorDescription: String? {
            switch self {
            case .untrustedDirectory(let message), .untrustedFile(let message): return message
            }
        }
    }

    /// Throws unless the directory is owned by the current user and neither
    /// group nor others can write to it.
    public static func checkTrusted(directory: URL) throws {
        let info = try checkOwned(directory: directory)
        guard info.st_mode & 0o022 == 0 else {
            throw TrustError.untrustedDirectory("\(directory.path) is writable by other users; refusing to use it")
        }
    }

    /// Throws unless the directory is owned by the current user. The first half of
    /// `checkTrusted(directory:)`, for callers that `chmod` the folder before the
    /// full check.
    @discardableResult
    public static func checkOwned(directory: URL) throws -> stat {
        var info = stat()
        guard stat(directory.path, &info) == 0 else { throw lastError() }
        guard info.st_uid == getuid() else {
            throw TrustError.untrustedDirectory("\(directory.path) belongs to another user; refusing to use it")
        }
        return info
    }

    /// No error when the file is missing. Otherwise it must be a regular file
    /// owned by the current user (`stat` follows symlinks, so a symlink to the
    /// user's own file is fine).
    public static func checkTrusted(file: URL) throws {
        var info = stat()
        if stat(file.path, &info) != 0 {
            if errno == ENOENT { return }
            throw lastError()
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw TrustError.untrustedFile("\(file.path) is not a regular file owned by you; refusing to use it")
        }
    }

    /// `mkdir -p` with mode 0700; an existing directory is `chmod`ed to 0700.
    /// Only for directories Relay owns (the default config directory and the
    /// data directory); see `createDirectoryIfMissing` for any other.
    public static func ensureDirectory(_ dir: URL) throws {
        try createDirectoryIfMissing(dir)
        guard chmod(dir.path, 0o700) == 0 else { throw lastError() }
    }

    /// `mkdir -p` with mode 0700. An existing directory is left as it is, so a
    /// custom `$RELAY_CONFIG` in a shared folder never tightens that folder.
    public static func createDirectoryIfMissing(_ dir: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw POSIXError(.ENOTDIR) }
        } else {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    /// Writes `data` to a temp file in the target's directory, opened
    /// O_WRONLY|O_CREAT|O_EXCL with mode 0600, fsyncs it and renames it over
    /// `url`. The temp file is removed if any step fails. A missing parent is
    /// created 0700; an existing one is never chmodded, but it and an existing
    /// target must pass `checkTrusted`.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try createDirectoryIfMissing(dir)
        try checkTrusted(directory: dir)
        try checkTrusted(file: url)
        let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw lastError() }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw lastError()
                    }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw lastError() }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw lastError() }
        guard rename(temp.path, url.path) == 0 else { throw lastError() }
        renamed = true
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
