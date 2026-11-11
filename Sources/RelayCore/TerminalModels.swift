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

/// A shell command Hook runs in a new, visible terminal window (Update Mailbox…), so
/// prompts and output stay in front of the user. `doneFile` is created when the command
/// ends, so the app can tell.
public struct RunTarget: Sendable, Equatable {
    public let command: String
    public let doneFile: String
    public static let maxCommand = 4096

    /// Nil when the command is empty, longer than `maxCommand`, or holds a control or hidden
    /// character (a newline would run part of it), or `doneFile` isn't a safe absolute path.
    public init?(command: String, doneFile: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.problem(command: command) == nil, AskOrigin.isSafePath(doneFile) else { return nil }
        self.command = trimmed
        self.doneFile = doneFile
    }

    /// Why `command` can't be run, as the end of a sentence ("it has a line break"); nil
    /// when it can. Leading and trailing white space is ignored.
    public static func problem(command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "it is empty" }
        if trimmed.unicodeScalars.count > maxCommand { return "it is longer than \(maxCommand) characters" }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) { return "it has a line break" }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) {
            return "it has a control character"
        }
        if !isSafe(trimmed) { return "it has a hidden character" }
        return nil
    }

    static func isSafe(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !Sanitize.isHidden(scalar, as: .code)
        }
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
