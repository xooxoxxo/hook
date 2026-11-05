import Foundation
import RelayCore

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
        # install.sh tells Hook the updater is quitting it (quit-request.json).
        export HOOK_QUIT_BY=updater
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
