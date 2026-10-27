import Testing
@testable import RelayCore

private func status(_ key: String = "mailbox:m#p", reachable: Bool = true, loadedOnce: Bool = true, problem: String? = nil,
                    config: String? = nil, listener: String? = nil, away: Bool = false, sending: Int = 0) -> PanelStatus {
    PanelStatus.make(StatusInputs(sourceKey: key, reachable: reachable, loadedOnce: loadedOnce, problem: problem,
                                  configNote: config, listenerNote: listener, away: away, sendingCloses: sending))
}

@Suite struct PanelStatusTests {
    @Test func readyAndConnecting() {
        #expect(status("local") == PanelStatus(symbol: .ok, text: "This Mac · ready", detail: .updated))
        #expect(status() == PanelStatus(symbol: .ok, text: "Mailbox · ready", detail: .updated))
        #expect(status("local", reachable: false, loadedOnce: false) == PanelStatus(symbol: .connecting, text: "This Mac · starting…", detail: .updated))
        #expect(status(reachable: false, loadedOnce: false) == PanelStatus(symbol: .connecting, text: "Mailbox · connecting…", detail: .updated))
    }

    @Test func problems() {
        #expect(status(reachable: false, problem: "timed\nout")
            == PanelStatus(symbol: .down, text: "Mailbox · offline", detail: .unreachable(reason: "timed⟨U+000A⟩out")))
        #expect(status("local", reachable: false, problem: "Hook is already running")
            == PanelStatus(symbol: .down, text: "This Mac · not ready", detail: .unreachable(reason: "Hook is already running")))
        #expect(status(config: "config.json has an error: not valid JSON")
            == PanelStatus(symbol: .down, text: "config.json has an error", detail: .config(note: "config.json has an error: not valid JSON")))
        #expect(status(listener: "Port 47823 is in use by another app")
            == PanelStatus(symbol: .down, text: "Links aren't working", detail: .listener(note: "Port 47823 is in use by another app")))
        #expect(status(SourceKey.none, reachable: false, loadedOnce: false, problem: "No queue is set up")
            == PanelStatus(symbol: .notSetUp, text: "Not set up", detail: .notSetUp))
    }

    @Test func priority() {
        #expect(status(reachable: false, problem: "x", config: "c", listener: "l", sending: 2).text == "Sending 2 closes…")
        #expect(status(sending: 1) == PanelStatus(symbol: .connecting, text: "Sending 1 close…", detail: .none))
        #expect(status(SourceKey.none, reachable: false, config: "c").text == "Not set up")
        #expect(status(reachable: false, problem: "x", config: "c", listener: "l").text == "config.json has an error")
        #expect(status(reachable: false, problem: "x", listener: "l").text == "Mailbox · offline")
    }

    @Test func away() {
        #expect(status(away: true) == PanelStatus(symbol: .away, text: "Away · Mailbox · ready", detail: .updated))
        #expect(status(reachable: false, problem: "x", away: true) == PanelStatus(symbol: .down, text: "Away · Mailbox · offline", detail: .unreachable(reason: "x")))
        #expect(status(reachable: false, loadedOnce: false, away: true).symbol == .away)
        #expect(status(SourceKey.none, reachable: false, away: true).text == "Away · Not set up")
    }
}

@Suite struct ConnectionStatusTests {
    @Test func lines() {
        #expect(ConnectionStatus.line(sourceKey: "mailbox:m#p", reachable: true, loadedOnce: true, waiting: 5, problem: nil)
            == ConnectionLine(text: "Connected · 5 waiting", ok: true))
        #expect(ConnectionStatus.line(sourceKey: "local", reachable: true, loadedOnce: true, waiting: 0, problem: nil)
            == ConnectionLine(text: "Ready · 0 waiting", ok: true))
        #expect(ConnectionStatus.line(sourceKey: "mailbox:m#p", reachable: false, loadedOnce: false, waiting: 0, problem: nil)
            == ConnectionLine(text: "Connecting…", ok: false))
        #expect(ConnectionStatus.line(sourceKey: "mailbox:m#p", reachable: false, loadedOnce: true, waiting: 3, problem: "timed out")
            == ConnectionLine(text: "Can't reach the mailbox: timed out", ok: false))
        #expect(ConnectionStatus.line(sourceKey: "local", reachable: false, loadedOnce: false, waiting: 0, problem: "Port\n47823")
            == ConnectionLine(text: "This Mac isn't ready: Port⟨U+000A⟩47823", ok: false))
        #expect(ConnectionStatus.line(sourceKey: "none", reachable: false, loadedOnce: false, waiting: 0, problem: "No queue is set up")
            == ConnectionLine(text: "No queue set up", ok: false))
    }

    @Test func menuStatusLine() {
        #expect(MenuStatusLine.text(sourceKey: "mailbox:m#p", reachable: true, updated: "10:42") == "Mailbox · ready · updated 10:42")
        #expect(MenuStatusLine.text(sourceKey: "mailbox:m#p", reachable: true, updated: nil) == "Mailbox · ready")
        #expect(MenuStatusLine.text(sourceKey: "mailbox:m#p", reachable: false, updated: "10:42") == "Mailbox · offline")
        #expect(MenuStatusLine.text(sourceKey: "local", reachable: true, updated: "10:42") == "This Mac · ready")
        #expect(MenuStatusLine.text(sourceKey: "local", reachable: false, updated: nil) == "This Mac · not ready")
        #expect(MenuStatusLine.text(sourceKey: "none", reachable: false, updated: nil) == "No queue set up")
    }
}
