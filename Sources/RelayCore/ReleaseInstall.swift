import CryptoKit
import Foundation

/// How this Hook was installed, read from the config's `repoPath`.
public enum InstallKind: Equatable, Sendable {
    /// A release download (scripts/get.sh): `repoPath` is `~/.local/share/hook/current`;
    /// `home` is the folder that holds the versions.
    case release(home: String)
    /// A git checkout, a developer's install: updates move it to the release tag and rebuild.
    case checkout(repo: String)
    /// No `repoPath`, or a folder that is neither.
    case unknown

    /// A folder with `.git` is a checkout; one with the payload's `VERSION` and
    /// `scripts/get.sh` is a release download.
    public static func detect(repoPath: String?, fileExists: (String) -> Bool) -> InstallKind {
        guard let raw = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .unknown }
        let repo = ConnectInfo.normalized(raw)
        guard repo.hasPrefix("/") else { return .unknown }
        if fileExists(repo + "/.git") { return .checkout(repo: repo) }
        if fileExists(repo + "/VERSION"), fileExists(repo + "/scripts/get.sh") {
            return .release(home: (repo as NSString).deletingLastPathComponent)
        }
        return .unknown
    }

    /// Settings › General › Updates.
    public func line(home: String) -> InstallLine {
        switch self {
        case .release(let hookHome):
            let current = TildePath.abbreviate(hookHome + "/current", home: home)
            return InstallLine(
                mode: "Release download",
                detail: "Check for Updates downloads the newest release from GitHub, checks it against the release's SHA256SUMS and installs it. No git or compiler needed. Files: \(current).")
        case .checkout(let repo):
            let path = TildePath.abbreviate(repo, home: home)
            return InstallLine(
                mode: "Developer checkout",
                detail: "Hook runs from the git checkout \(path). Check for Updates moves it to the newest release tag and rebuilds Hook from source, which needs the Command Line Tools.")
        case .unknown:
            return InstallLine(
                mode: "Not known",
                detail: "Hook can't tell how it was installed, so it can't update itself. Install it again with scripts/get.sh (see the README).")
        }
    }
}

/// The Updates row: which install this is, and what Check for Updates does with it.
public struct InstallLine: Equatable, Sendable {
    public var mode: String
    public var detail: String
    public init(mode: String, detail: String) {
        self.mode = mode
        self.detail = detail
    }
}

/// The files a release carries for a release-download install.
public enum ReleaseAssets {
    /// Release files download from the repo's new name; GitHub sends them on to its file host.
    public static let downloadBase = URL(string: "https://github.com/xooxoxxo/hook/releases/download")!
    public static let sumsName = "SHA256SUMS"

    public static func zipName(_ version: ReleaseVersion) -> String { "Hook-\(version).zip" }

    public static func url(tag: String, file: String) -> URL {
        downloadBase.appending(path: tag).appending(path: file)
    }

    /// The lowercase SHA-256 that a `shasum -a 256` line ("<hash>  <name>", or " *<name>")
    /// gives `name`; nil when no well-formed line names it.
    public static func checksum(in sums: String, for name: String) -> String? {
        for raw in sums.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 66 else { continue }
            let hash = line.prefix(64)
            var rest = line.dropFirst(64)
            guard rest.first == " " else { continue }
            rest = rest.dropFirst()
            if rest.first == " " || rest.first == "*" { rest = rest.dropFirst() }
            guard rest == name, hash.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { continue }
            return hash.lowercased()
        }
        return nil
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// nil when `data` is the file SHA256SUMS lists as `name`; else why it isn't.
    public static func verify(_ data: Data, sums: String, name: String) -> UpdateCheckError? {
        guard let expected = checksum(in: sums, for: name) else {
            return UpdateCheckError("The release's SHA256SUMS doesn't list \(name).")
        }
        guard sha256(data) == expected else {
            return UpdateCheckError("\(name) doesn't match the release's SHA256SUMS, so it wasn't installed.")
        }
        return nil
    }
}
