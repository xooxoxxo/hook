import Testing
@testable import RelayCore

private func status(_ key: String = "mailbox:m#p", reachable: Bool = true, loadedOnce: Bool = true, problem: String? = nil,
                    config: String? = nil, listener: String? = nil, away: Bool = false, sending: Int = 0,
                    updating: Bool = false) -> PanelStatus {
    PanelStatus.make(StatusInputs(sourceKey: key, reachable: reachable, loadedOnce: loadedOnce, problem: problem,
                                  configNote: config, listenerNote: listener, away: away, sendingCloses: sending,
                                  updating: updating))
}

@Suite struct PanelStatusTests {
    /// Quiet when fine: the Pond is the word "Pond" in green, This Mac shows nothing.
    @Test func readyAndConnecting() {
        #expect(status("local") == PanelStatus(symbol: .ok, text: "", detail: .updated, tone: .ok, spoken: "This Mac, ready"))
        #expect(status() == PanelStatus(symbol: .ok, text: "Pond", detail: .updated, tone: .ok, spoken: "Pond, ready"))
        #expect(status("local", reachable: false, loadedOnce: false)
            == PanelStatus(symbol: .connecting, text: "Starting…", detail: .updated, tone: .neutral))
        #expect(status(reachable: false, loadedOnce: false)
            == PanelStatus(symbol: .connecting, text: "Connecting…", detail: .updated, tone: .neutral))
    }

    @Test func problems() {
        #expect(status(reachable: false, problem: "timed\nout")
            == PanelStatus(symbol: .down, text: "Offline", detail: .unreachable(reason: "timed⟨U+000A⟩out"), tone: .warn))
        #expect(status("local", reachable: false, problem: "Hook is already running")
            == PanelStatus(symbol: .down, text: "Not ready", detail: .unreachable(reason: "Hook is already running"), tone: .warn))
        #expect(status(config: "config.json has an error: not valid JSON")
            == PanelStatus(symbol: .down, text: "config.json has an error",
                           detail: .config(note: "config.json has an error: not valid JSON"), tone: .warn))
        #expect(status(listener: "Port 47823 is in use by another app")
            == PanelStatus(symbol: .down, text: "Links aren't working",
                           detail: .listener(note: "Port 47823 is in use by another app"), tone: .warn))
        #expect(status(SourceKey.none, reachable: false, loadedOnce: false, problem: "No queue is set up")
            == PanelStatus(symbol: .notSetUp, text: "Not set up", detail: .notSetUp, tone: .neutral))
    }

    @Test func updating() {
        #expect(status(updating: true) == PanelStatus(symbol: .connecting, text: "Updating…", detail: .none, tone: .neutral))
        #expect(status("local", reachable: false, problem: "x", updating: true).text == "Updating…")
        #expect(status(sending: 2, updating: true).text == "Sending 2 closes…")
    }

    @Test func priority() {
        #expect(status(reachable: false, problem: "x", config: "c", listener: "l", sending: 2).text == "Sending 2 closes…")
        #expect(status(sending: 1) == PanelStatus(symbol: .connecting, text: "Sending 1 close…", detail: .none, tone: .neutral))
        #expect(status(SourceKey.none, reachable: false, config: "c").text == "Not set up")
        #expect(status(reachable: false, problem: "x", config: "c", listener: "l").text == "config.json has an error")
        #expect(status(reachable: false, problem: "x", listener: "l").text == "Offline")
    }

    @Test func away() {
        #expect(status(away: true) == PanelStatus(symbol: .away, text: "Away · Pond", detail: .updated, tone: .ok,
                                               spoken: "Away, Pond, ready"))
        #expect(status("local", away: true) == PanelStatus(symbol: .away, text: "Away", detail: .updated, tone: .neutral,
                                                        spoken: "Away, This Mac, ready"))
        #expect(status(reachable: false, problem: "x", away: true)
            == PanelStatus(symbol: .down, text: "Away · Offline", detail: .unreachable(reason: "x"), tone: .warn,
                           spoken: "Away, Offline"))
        #expect(status(reachable: false, loadedOnce: false, away: true).symbol == .away)
        #expect(status(SourceKey.none, reachable: false, away: true).text == "Away · Not set up")
    }

    /// VoiceOver hears the state in words, never an empty label.
    @Test func spoken() {
        #expect(status().spoken == "Pond, ready")
        #expect(status("local").spoken == "This Mac, ready")
        #expect(status(reachable: false, problem: "x").spoken == "Offline")
        #expect(status(away: true).spoken == "Away, Pond, ready")
        #expect(status("local", away: true).spoken == "Away, This Mac, ready")
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
            == ConnectionLine(text: "Can't reach the Pond: timed out", ok: false))
        #expect(ConnectionStatus.line(sourceKey: "local", reachable: false, loadedOnce: false, waiting: 0, problem: "Port\n47823")
            == ConnectionLine(text: "This Mac isn't ready: Port⟨U+000A⟩47823", ok: false))
        #expect(ConnectionStatus.line(sourceKey: "none", reachable: false, loadedOnce: false, waiting: 0, problem: "No queue is set up")
            == ConnectionLine(text: "No queue set up", ok: false))
    }

    @Test func menuStatusLine() {
        #expect(MenuStatusLine.text(sourceKey: "mailbox:m#p", reachable: true, updated: "10:42") == "Pond · ready · updated 10:42")
        #expect(MenuStatusLine.text(sourceKey: "mailbox:m#p", reachable: true, updated: nil) == "Pond · ready")
        #expect(MenuStatusLine.text(sourceKey: "mailbox:m#p", reachable: false, updated: "10:42") == "Pond · offline")
        #expect(MenuStatusLine.text(sourceKey: "local", reachable: true, updated: "10:42") == "This Mac · ready")
        #expect(MenuStatusLine.text(sourceKey: "local", reachable: false, updated: nil) == "This Mac · not ready")
        #expect(MenuStatusLine.text(sourceKey: "none", reachable: false, updated: nil) == "No queue set up")
    }
}
