import Foundation

/// A release version: `X.Y.Z`, with an optional leading "v". Anything else (a
/// pre-release suffix, a fourth part, a leading zero, letters) does not parse.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0", let n = Int(part) else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The parts of GitHub's "latest release" reply that Hook reads.
public struct LatestRelease: Equatable, Sendable {
    /// The git tag, exactly as GitHub gives it ("v0.6.5").
    public let tag: String
    public let version: ReleaseVersion
    /// The release page, for the release notes.
    public let url: URL
    /// The mailbox level the release needs: its notes' `<!-- hook:mailbox-protocol=N -->`
    /// marker, or nil when the notes have none.
    public let mailboxLevel: Int?

    public init(tag: String, version: ReleaseVersion, url: URL, mailboxLevel: Int? = nil) {
        self.tag = tag
        self.version = version
        self.url = url
        self.mailboxLevel = mailboxLevel
    }

    /// nil for a reply that isn't a published, final release with a version tag and an https page.
    public static func parse(_ data: Data) -> LatestRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = ReleaseVersion(tag),
              let page = object["html_url"] as? String,
              let url = URL(string: page), url.scheme == "https", url.host != nil else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        let level = (object["body"] as? String).flatMap(ReleaseMarker.mailboxLevel(in:))
        return LatestRelease(tag: tag, version: version, url: url, mailboxLevel: level)
    }
}

/// What the menu knows about updates.
public enum UpdateState: Equatable, Sendable {
    case none
    case checking
    case available(version: String, tag: String, url: URL)
    case failed(reason: String)

    /// An update only when the release is strictly newer than the running version.
    /// A running version that doesn't parse (a development build) never offers one.
    public static func resolve(current: String, latest: LatestRelease?) -> UpdateState {
        guard let latest, let running = ReleaseVersion(current), latest.version > running else { return .none }
        return .available(version: latest.version.description, tag: latest.tag, url: latest.url)
    }

    /// The result of one check: the reply's body, or why there is none.
    public static func resolve(current: String, reply: Result<Data, UpdateCheckError>) -> UpdateState {
        switch reply {
        case .failure(let error):
            return .failed(reason: error.reason)
        case .success(let data):
            guard let latest = LatestRelease.parse(data) else {
                return .failed(reason: "GitHub's reply had no release version")
            }
            return resolve(current: current, latest: latest)
        }
    }

    public var availableVersion: String? {
        if case .available(let version, _, _) = self { return version }
        return nil
    }
}

public struct UpdateCheckError: LocalizedError, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Automatic checks: about a minute after launch, then once a day.
public enum UpdateSchedule {
    public static let firstDelay: TimeInterval = 60
    public static let interval: TimeInterval = 24 * 60 * 60
}

/// Whether the checkout can be moved to a release without losing anything.
public enum UpdateGate {
    /// How the checkout moves to the release tag.
    public enum Mode: Equatable, Sendable {
        /// On main: a fast-forward merge to the tag.
        case fastForward
        /// Detached at a release tag: a checkout of the new tag.
        case checkout
    }

    public enum Verdict: Equatable, Sendable {
        case ok(Mode)
        case refused(String)
    }

    /// `porcelain` is `git status --porcelain`; `branch` is `git branch --show-current`
    /// (empty when detached); `headTag` is `git describe --tags --exact-match HEAD`, or nil.
    public static func check(porcelain: String, branch: String, headTag: String?) -> Verdict {
        let changes = porcelain.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !changes.isEmpty {
            let files = changes.count == 1 ? "1 file has" : "\(changes.count) files have"
            return .refused("The Hook checkout has changes that aren't committed (\(files) changed). Commit or stash them, then try again.")
        }
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "main" { return .ok(.fastForward) }
        if name.isEmpty {
            if let tag = headTag?.trimmingCharacters(in: .whitespacesAndNewlines), tag.hasPrefix("v"),
               ReleaseVersion(tag) != nil {
                return .ok(.checkout)
            }
            return .refused("The Hook checkout isn't on a branch or a release tag. Switch it to main, then try again.")
        }
        return .refused("The Hook checkout is on the branch “\(Sanitize.revealLine(name))”, not main. Switch it to main, then try again.")
    }

    /// The repo's names on GitHub: `relay` from before the rename, `hook` after it.
    /// Clones made before the rename keep the old URL, which GitHub redirects.
    public static let repoNames = ["xooxoxxo/relay", "xooxoxxo/hook"]

    /// The release check stays on the old path: GitHub redirects it after the rename,
    /// and it is the one installed 0.7.x apps ask too.
    public static let latestReleaseAPI = "https://api.github.com/repos/xooxoxxo/relay/releases/latest"

    /// `git remote get-url origin` names github.com/xooxoxxo/relay or github.com/xooxoxxo/hook,
    /// over https or ssh.
    public static func isRepoOrigin(_ url: String) -> Bool {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return repoNames.contains { name in
            ["https://github.com/" + name, "ssh://git@github.com/" + name, "git@github.com:" + name].contains(text)
        }
    }
}

/// The detached job that moves the checkout to the release and runs install.sh.
public struct UpdatePlan: Equatable, Sendable {
    public static let jobLabel = "io.github.xooxoxxo.relay.update"

    public var repoPath: String
    public var tag: String
    public var mode: UpdateGate.Mode
    public var current: String
    public var appPath: String
    public var logPath: String
    public var scriptPath: String
    public var plistPath: String
    public var home: String

    public init(repoPath: String, tag: String, mode: UpdateGate.Mode, current: String, appPath: String,
                logPath: String, scriptPath: String, plistPath: String, home: String) {
        self.repoPath = repoPath
        self.tag = tag
        self.mode = mode
        self.current = current
        self.appPath = appPath
        self.logPath = logPath
        self.scriptPath = scriptPath
        self.plistPath = plistPath
        self.home = home
    }

    /// The command that moves the checkout to the tag.
    public var moveCommand: String {
        switch mode {
        case .fastForward: return "/usr/bin/git merge --ff-only " + Shell.quote(tag)
        case .checkout: return "/usr/bin/git checkout --quiet " + Shell.quote(tag)
        }
    }

    /// The move step as the log names it.
    var moveStep: String {
        switch mode {
        case .fastForward: return "git merge --ff-only " + tag
        case .checkout: return "git checkout " + tag
        }
    }

    /// The script the job runs. Each step that fails logs which one, and Hook is
    /// started again if install.sh had already quit it. The job removes itself at the end.
    /// install.sh does the quit and restart: it force-quits a copy that hangs on quit and
    /// checks that the copy it started is the new one, so the job needs no quit of its own.
    public var script: String {
        let repo = Shell.quote(repoPath)
        let app = Shell.quote(appPath)
        return """
        #!/bin/sh
        export HOME=\(Shell.quote(home))
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        finish() {
          rm -f \(Shell.quote(plistPath)) \(Shell.quote(scriptPath))
          exec /bin/launchctl remove \(Shell.quote(Self.jobLabel))
        }
        fail() {
          echo "update: failed: $1"
          /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Hook >/dev/null 2>&1 || /usr/bin/open -g -a \(app)
          finish
        }
        echo "update: $(/bin/date '+%Y-%m-%d %H:%M:%S') Hook" \(Shell.quote(current)) "->" \(Shell.quote(tag)) "in" \(repo)
        cd \(repo) || fail "couldn't open the checkout"
        /usr/bin/git fetch origin --tags || fail "git fetch origin --tags"
        \(moveCommand) || fail \(Shell.quote(moveStep))
        ./scripts/install.sh || fail "./scripts/install.sh"
        echo "update: done, Hook is now" \(Shell.quote(tag))
        finish

        """
    }

    /// A one-shot LaunchAgent: launchd runs the script outside Hook, so it survives
    /// install.sh quitting Hook, and never runs it again.
    public var jobPlist: [String: Any] {
        [
            "Label": Self.jobLabel,
            "ProgramArguments": ["/bin/sh", scriptPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "AbandonProcessGroup": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "WorkingDirectory": repoPath,
        ]
    }

    /// The launchctl calls, in order: drop a stale job of the same label, then load this one.
    public func launchCommands(uid: UInt32) -> [[String]] {
        [
            ["/bin/launchctl", "bootout", "gui/\(uid)/\(Self.jobLabel)"],
            ["/bin/launchctl", "bootstrap", "gui/\(uid)", plistPath],
        ]
    }
}

public enum Shell {
    /// A single-quoted shell word.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
