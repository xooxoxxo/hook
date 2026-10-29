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

/// A one-shot launchd job that updates Hook: launchd runs the script outside Hook, so it
/// survives install.sh quitting Hook, and never runs it again.
public protocol UpdateJob {
    var script: String { get }
    var scriptPath: String { get }
    var plistPath: String { get }
    var logPath: String { get }
    var workingDirectory: String { get }
}

extension UpdateJob {
    public var jobPlist: [String: Any] {
        [
            "Label": UpdatePlan.jobLabel,
            "ProgramArguments": ["/bin/sh", scriptPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "AbandonProcessGroup": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "WorkingDirectory": workingDirectory,
        ]
    }

    /// The launchctl calls, in order: drop a stale job of the same label, then load this one.
    public func launchCommands(uid: UInt32) -> [[String]] {
        [
            ["/bin/launchctl", "bootout", "gui/\(uid)/\(UpdatePlan.jobLabel)"],
            ["/bin/launchctl", "bootstrap", "gui/\(uid)", plistPath],
        ]
    }
}

/// The update of a release-download install: the job hands the zip and SHA256SUMS Hook
/// already downloaded and checked to the installed `current/scripts/get.sh`, which checks
/// them again, puts the new version next to the old one and runs its `install.sh --prebuilt`.
public struct ReleaseUpdatePlan: UpdateJob, Equatable, Sendable {
    public var hookHome: String
    public var tag: String
    public var version: ReleaseVersion
    public var current: String
    public var appPath: String
    public var downloadDir: String
    public var zipPath: String
    public var sumsPath: String
    public var logPath: String
    public var scriptPath: String
    public var plistPath: String
    public var home: String

    public init(hookHome: String, tag: String, version: ReleaseVersion, current: String, appPath: String,
                downloadDir: String, zipPath: String, sumsPath: String, logPath: String, scriptPath: String,
                plistPath: String, home: String) {
        self.hookHome = hookHome
        self.tag = tag
        self.version = version
        self.current = current
        self.appPath = appPath
        self.downloadDir = downloadDir
        self.zipPath = zipPath
        self.sumsPath = sumsPath
        self.logPath = logPath
        self.scriptPath = scriptPath
        self.plistPath = plistPath
        self.home = home
    }

    public var workingDirectory: String { hookHome }

    public var script: String {
        let app = Shell.quote(appPath)
        return """
        #!/bin/sh
        export HOME=\(Shell.quote(home))
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        finish() {
          rm -rf \(Shell.quote(downloadDir))
          rm -f \(Shell.quote(plistPath)) \(Shell.quote(scriptPath))
          exec /bin/launchctl remove \(Shell.quote(UpdatePlan.jobLabel))
        }
        fail() {
          echo "update: failed: $1"
          /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Hook >/dev/null 2>&1 || /usr/bin/open -g -a \(app)
          finish
        }
        echo "update: $(/bin/date '+%Y-%m-%d %H:%M:%S') Hook" \(Shell.quote(current)) "->" \(Shell.quote(tag)) "from the release download"
        cd \(Shell.quote(hookHome)) || fail "couldn't open the Hook folder"
        HOOK_VERSION=\(Shell.quote(version.description)) HOOK_ZIP=\(Shell.quote(zipPath)) HOOK_SUMS=\(Shell.quote(sumsPath)) /bin/bash \(Shell.quote(hookHome + "/current/scripts/get.sh")) || fail "scripts/get.sh"
        echo "update: done, Hook is now" \(Shell.quote(tag))
        finish

        """
    }
}
