import Foundation

/// What the status bar needs to know (design §4.3, status table).
public struct StatusInputs: Equatable, Sendable {
    public var sourceKey: String
    public var reachable: Bool
    public var loadedOnce: Bool
    /// Why the last list failed; nil when it worked or none ran yet.
    public var problem: String?
    public var configNote: String?
    public var listenerNote: String?
    public var away: Bool
    /// Held closes being sent on quit.
    public var sendingCloses: Int

    public init(sourceKey: String, reachable: Bool, loadedOnce: Bool, problem: String? = nil, configNote: String? = nil,
                listenerNote: String? = nil, away: Bool = false, sendingCloses: Int = 0) {
        self.sourceKey = sourceKey
        self.reachable = reachable
        self.loadedOnce = loadedOnce
        self.problem = problem
        self.configNote = configNote
        self.listenerNote = listenerNote
        self.away = away
        self.sendingCloses = sendingCloses
    }
}

/// What the status button's popover shows.
public enum StatusDetail: Equatable, Sendable {
    case updated, unreachable(reason: String), config(note: String), listener(note: String), notSetUp, none
}

public struct PanelStatus: Equatable, Sendable {
    public var symbol: StatusSymbol
    public var text: String
    public var detail: StatusDetail

    public init(symbol: StatusSymbol, text: String, detail: StatusDetail) {
        self.symbol = symbol
        self.text = text
        self.detail = detail
    }

    public static func make(_ inputs: StatusInputs) -> PanelStatus {
        if inputs.sendingCloses > 0 {
            let n = inputs.sendingCloses
            return PanelStatus(symbol: .connecting, text: "Sending \(n) \(n == 1 ? "close" : "closes")…", detail: .none)
        }
        let local = inputs.sourceKey == SourceKey.local
        let name = local ? "This Mac" : "Mailbox"
        var status: PanelStatus
        if inputs.sourceKey == SourceKey.none {
            status = PanelStatus(symbol: .notSetUp, text: "Not set up", detail: .notSetUp)
        } else if let note = inputs.configNote {
            status = PanelStatus(symbol: .down, text: "config.json has an error", detail: .config(note: note))
        } else if !inputs.reachable, let problem = inputs.problem {
            status = PanelStatus(symbol: .down, text: name + (local ? " · not ready" : " · offline"),
                                 detail: .unreachable(reason: UserFacingError.text(problem)))
        } else if let note = inputs.listenerNote {
            status = PanelStatus(symbol: .down, text: "Links aren't working", detail: .listener(note: note))
        } else if !inputs.reachable {
            status = PanelStatus(symbol: .connecting, text: name + (local ? " · starting…" : " · connecting…"), detail: .updated)
        } else {
            status = PanelStatus(symbol: .ok, text: name + " · ready", detail: .updated)
        }
        if inputs.away {
            status.text = "Away · " + status.text
            if status.symbol != .down { status.symbol = .away }
        }
        return status
    }
}

/// Settings → Queue → Connection → Status.
public struct ConnectionLine: Equatable, Sendable {
    public var text: String
    public var ok: Bool

    public init(text: String, ok: Bool) {
        self.text = text
        self.ok = ok
    }
}

public enum ConnectionStatus {
    public static func line(sourceKey: String, reachable: Bool, loadedOnce: Bool, waiting: Int, problem: String?) -> ConnectionLine {
        if sourceKey == SourceKey.none { return ConnectionLine(text: "No queue set up", ok: false) }
        let local = sourceKey == SourceKey.local
        if reachable { return ConnectionLine(text: (local ? "Ready" : "Connected") + " · \(waiting) waiting", ok: true) }
        guard let problem else { return ConnectionLine(text: "Connecting…", ok: false) }
        let prefix = local ? "This Mac isn't ready: " : "Can't reach the mailbox: "
        return ConnectionLine(text: prefix + UserFacingError.text(problem), ok: false)
    }
}

/// The menu-bar menu's disabled status line.
public enum MenuStatusLine {
    public static func text(sourceKey: String, reachable: Bool, updated: String?) -> String {
        if sourceKey == SourceKey.none { return "No queue set up" }
        if sourceKey == SourceKey.local { return reachable ? "This Mac · ready" : "This Mac · not ready" }
        guard reachable else { return "Mailbox · offline" }
        return "Mailbox · ready" + (updated.map { " · updated " + $0 } ?? "")
    }
}
