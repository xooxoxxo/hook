import Foundation

/// A terminal Hook can resume a Claude Code session in.
public enum TerminalKind: String, CaseIterable, Sendable {
    case terminal, iterm, ghostty, kitty, wezterm, warp, alacritty

    public var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .kitty: "net.kovidgoyal.kitty"
        case .wezterm: "com.github.wez.wezterm"
        case .warp: "dev.warp.Warp-Stable"
        case .alacritty: "org.alacritty"
        }
    }

    public var name: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .kitty: "kitty"
        case .wezterm: "WezTerm"
        case .warp: "Warp"
        case .alacritty: "Alacritty"
        }
    }

    public init?(bundleID: String) {
        guard let kind = Self.allCases.first(where: { $0.bundleID.lowercased() == bundleID.lowercased() }) else {
            return nil
        }
        self = kind
    }

    /// Automatic's order: the first of these that is installed, else Terminal.
    public static let automaticOrder: [TerminalKind] = [.ghostty, .iterm, .wezterm, .kitty, .warp, .alacritty]

    /// What Automatic opens with these terminals installed.
    public static func automatic(installed: Set<TerminalKind>) -> TerminalKind {
        automaticOrder.first(where: installed.contains) ?? .terminal
    }

    /// The `terminal` config value: a known bundle id that is installed is that terminal;
    /// "automatic", anything unknown or a terminal that isn't installed is `automatic(installed:)`.
    public static func resolve(_ setting: String, installed: Set<TerminalKind>) -> TerminalKind {
        guard let kind = TerminalKind(bundleID: setting.trimmingCharacters(in: .whitespacesAndNewlines)),
              kind == .terminal || installed.contains(kind) else { return automatic(installed: installed) }
        return kind
    }
}

/// The two values a resume needs, both already checked by `AskOrigin`: a session id
/// that matches its pattern and an absolute path free of control and hidden characters.
public struct ResumeTarget: Sendable, Equatable {
    public let cwd: String
    public let session: String

    /// Nil unless the origin has a resume command.
    public init?(_ origin: AskOrigin?) {
        guard let origin, origin.resumeCommand != nil, let cwd = origin.cwd, let session = origin.session else {
            return nil
        }
        self.cwd = cwd
        self.session = session
    }
}

/// One way to open a terminal. The app layer runs it; nothing here touches the system.
public enum LaunchStep: Equatable, Sendable {
    /// Write `body` to a private, executable `.command` file and open it with the app.
    case commandFile(body: String, bundleID: String)
    /// `open -na <app> --args …`: a new instance of the app with these arguments.
    case openNew(bundleID: String, arguments: [String])
    /// Run `executable` (a path inside the app bundle) with `arguments`. With
    /// `waits`, a non-zero exit counts as a failure; otherwise it runs detached.
    case process(bundleID: String, executable: String, arguments: [String], waits: Bool)
    /// `osascript -e <source> <arguments…>`: the values reach the script as `argv`,
    /// never as script source.
    case appleScript(source: String, arguments: [String])
    /// Write `contents` to `file` (a path under the home folder), then open `url`.
    case fileThenURL(file: String, contents: String, url: URL)
}

/// The steps for one resume, tried in order: the next one runs only when the one
/// before it failed. When all fail, the app shows a Notice and copies the command.
public struct LaunchPlan: Equatable, Sendable {
    public var terminal: TerminalKind
    public var steps: [LaunchStep]
}

/// Plans a resume for each terminal. Every plan goes through the user's login shell,
/// so `~/.local/bin` is on PATH, and passes the folder and session as separate
/// arguments wherever the terminal allows it.
public enum TerminalLauncher {
    /// `$0` for the shell's `-c` script.
    static let scriptName = "hook-resume"
    /// Run by `<shell> -lc`; `$1` is the folder and `$2` the session.
    public static let shellScript = #"cd -- "$1" && exec claude --resume "$2""#
    /// Shells that read `-c script name arg…` the POSIX way.
    static let posixShells: Set<String> = ["sh", "bash", "zsh", "ksh", "dash"]
    public static let fallbackShell = "/bin/zsh"
    /// Warp's tab config, rewritten on each resume so the user's list gets one entry.
    public static let warpConfigName = "hook-resume"
    public static let warpConfigFile = ".warp/tab_configs/\(warpConfigName).toml"

    /// The login shell to run the script with: the user's shell when it is POSIX-like,
    /// otherwise zsh (fish and others read `-c` arguments differently).
    public static func shell(_ userShell: String?) -> String {
        guard let userShell, userShell.hasPrefix("/"),
              let name = userShell.split(separator: "/").last, posixShells.contains(String(name)) else {
            return fallbackShell
        }
        return userShell
    }

    /// `<shell> -lc <script> hook-resume <cwd> <session>`.
    public static func shellCommand(_ target: ResumeTarget, shell: String) -> [String] {
        [shell, "-lc", shellScript, scriptName, target.cwd, target.session]
    }

    /// `ghosttyVersion` is the installed app's CFBundleShortVersionString, when known.
    public static func plan(_ terminal: TerminalKind, target: ResumeTarget, shell userShell: String?,
                            ghosttyVersion: String? = nil) -> LaunchPlan {
        let shell = shell(userShell)
        let command = shellCommand(target, shell: shell)
        let steps: [LaunchStep]
        switch terminal {
        case .terminal, .iterm:
            steps = [.commandFile(body: commandFileBody(target), bundleID: terminal.bundleID)]
        case .ghostty:
            let openNew = LaunchStep.openNew(
                bundleID: terminal.bundleID,
                arguments: ["--working-directory=" + target.cwd, "-e"] + command)
            if supportsGhosttyScripting(ghosttyVersion) {
                steps = [.appleScript(source: ghosttyScript, arguments: [target.cwd, target.session]), openNew]
            } else {
                steps = [openNew]
            }
        case .kitty:
            steps = [.openNew(bundleID: terminal.bundleID, arguments: ["--directory", target.cwd] + command)]
        case .wezterm:
            steps = [.process(bundleID: terminal.bundleID, executable: "Contents/MacOS/wezterm",
                              arguments: ["start", "--cwd", target.cwd, "--"] + command, waits: false)]
        case .warp:
            steps = [.fileThenURL(file: warpConfigFile, contents: warpTabConfig(target),
                                  url: URL(string: "warp://tab_config/\(warpConfigName)?new_window=true")!)]
        case .alacritty:
            let tail = ["--working-directory", target.cwd, "-e"] + command
            steps = [
                .process(bundleID: terminal.bundleID, executable: "Contents/MacOS/alacritty",
                         arguments: ["msg", "create-window"] + tail, waits: true),
                .openNew(bundleID: terminal.bundleID, arguments: tail),
            ]
        }
        return LaunchPlan(terminal: terminal, steps: steps)
    }

    // MARK: - Terminal and iTerm2

    /// The `.command` file. Terminal and iTerm2 run it from a new window's login shell,
    /// so it inherits the user's PATH. It removes itself first. A file takes no
    /// arguments, so the values are single-quoted; AskOrigin has already refused
    /// control and hidden characters, and the session is letters, digits and dashes.
    public static func commandFileBody(_ target: ResumeTarget) -> String {
        """
        #!/bin/sh
        rm -f -- "$0"
        cd -- \(singleQuoted(target.cwd)) || exit 1
        exec claude --resume \(singleQuoted(target.session))

        """
    }

    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Ghostty

    /// Ghostty 1.3 added the AppleScript dictionary.
    public static func supportsGhosttyScripting(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        return major > 1 || (major == 1 && minor >= 3)
    }

    /// A new window in the session's folder whose login shell gets the resume command
    /// as typed input. `argv`: the folder, then the session.
    public static let ghosttyScript = """
        on run argv
            tell application id "com.mitchellh.ghostty"
                set cfg to new surface configuration
                set initial working directory of cfg to item 1 of argv
                set initial input of cfg to "claude --resume " & item 2 of argv & linefeed
                new window with configuration cfg
                activate
            end tell
        end run
        """

    // MARK: - Warp

    /// A tab config with one pane in the folder that runs the resume command in Warp's shell.
    public static func warpTabConfig(_ target: ResumeTarget) -> String {
        """
        name = "Hook resume"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = \(tomlString(target.cwd))
        commands = [\(tomlString("claude --resume " + target.session))]

        """
    }

    /// A TOML basic string. AskOrigin has refused control characters, so only `\` and `"` need escapes.
    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Whether "Resume Session" can run for an ask, and why not.
public enum ResumeAvailability: Equatable, Sendable {
    /// No resume command: no item at all.
    case none
    case available
    case unavailable(reason: String)

    /// Available only when the ask has a resume command and came from this Mac.
    public static func of(_ origin: AskOrigin?, localHost: String?) -> ResumeAvailability {
        guard ResumeTarget(origin) != nil, let origin else { return .none }
        guard let host = origin.host else { return .unavailable(reason: "Session is on an unknown Mac") }
        if let localHost, HostName.same(host, localHost) { return .available }
        return .unavailable(reason: "Session is on " + Sanitize.revealLine(host))
    }
}

/// Host-name comparison for "is this session on this Mac".
public enum HostName {
    /// This Mac's `gethostname()`, which is what the clients send as `from.host`.
    public static var current: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// Case-insensitive, on the first label: a Mac's name gains ".local" or a
    /// network's suffix depending on where it is.
    public static func same(_ a: String, _ b: String) -> Bool {
        let left = firstLabel(a), right = firstLabel(b)
        return !left.isEmpty && left == right
    }

    static func firstLabel(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

/// The Terminal picker in Settings › General.
public struct TerminalChoice: Equatable, Sendable, Identifiable {
    /// A bundle id, or `RelayConfig.automaticTerminal`.
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// Automatic, named after the terminal it resolves to ("Automatic (Ghostty)"), then each
    /// installed terminal in `TerminalKind` order. A saved terminal that isn't installed stays
    /// listed, marked, so the picker shows it.
    public static func options(installed: Set<TerminalKind>, current: String) -> [TerminalChoice] {
        let automatic = TerminalKind.automatic(installed: installed).name
        var options = [TerminalChoice(id: RelayConfig.automaticTerminal, title: "Automatic (\(automatic))")]
        for kind in TerminalKind.allCases where installed.contains(kind) {
            options.append(TerminalChoice(id: kind.bundleID, title: kind.name))
        }
        if current != RelayConfig.automaticTerminal, !options.contains(where: { $0.id == current }) {
            let name = TerminalKind(bundleID: current)?.name ?? Sanitize.revealLine(current)
            options.append(TerminalChoice(id: current, title: name + " (not installed)"))
        }
        return options
    }
}
