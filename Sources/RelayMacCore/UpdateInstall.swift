import Foundation
import RelayCore

/// Whether the checkout can be moved to a release without losing anything.
public enum UpdateGate {
    /// The gate's refusal when no checkout is known: it is chosen in Settings › Agents.
    public static let noCheckout =
        "Hook doesn't know where your checkout is. Set it in Settings › Agents, or run scripts/install.sh once."

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

    /// The release check asks the repo by its name since the rename. (The old path still
    /// redirects, for the 0.7.x to 0.11 apps that ask it.)
    public static let latestReleaseAPI = "https://api.github.com/repos/xooxoxxo/hook/releases/latest"

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
public struct UpdatePlan: UpdateJob, Equatable, Sendable {
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
        # install.sh tells Hook the updater is quitting it (quit-request.json).
        export HOOK_QUIT_BY=updater
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

    public var workingDirectory: String { repoPath }
}

public enum Shell {
    /// A single-quoted shell word.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
