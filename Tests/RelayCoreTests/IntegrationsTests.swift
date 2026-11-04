import Foundation
import Testing
@testable import RelayCore

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "integrations-status", withExtension: "json",
                                             subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func fixture() throws -> IntegrationStatus {
    try IntegrationStatus.decode(fixtureData())
}

/// The fixture as a mutable JSON object, for a changed copy.
private func fixtureObject() throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
}

private func harness(_ status: IntegrationStatus, _ id: String) throws -> IntegrationStatus.Harness {
    try #require(status.harnesses.first { $0.id == id })
}

private func piece(_ harness: IntegrationStatus.Harness, _ name: String) throws -> IntegrationStatus.Piece {
    try #require(harness.pieces.first { $0.piece == name })
}

private func makePiece(_ state: PieceState, method: String = "block", diffable: Bool = true,
                       target: String? = "~/.codex/AGENTS.md", reveal: String? = nil) -> IntegrationStatus.Piece {
    IntegrationStatus.Piece(piece: "instructions", method: method, state: state, target: target, key: nil, note: nil,
                            diffable: diffable, reveal: reveal)
}

private func makeHarness(_ state: HarnessState, pieces: [IntegrationStatus.Piece] = [],
                         steps: [IntegrationStatus.OwnerStep] = []) -> IntegrationStatus.Harness {
    IntegrationStatus.Harness(id: "codex", name: "Codex", detected: true, managed: true, state: state,
                              verified: "pending", pieces: pieces, ownerSteps: steps, changes: [])
}

@Suite struct IntegrationStatusDecodingTests {
    @Test func theFixtureDecodes() throws {
        let status = try fixture()
        #expect(status.schema == 1)
        #expect(status.hookVersion == "0.13.0")
        #expect(status.autoSetup == false)
        #expect(status.lastSync == Date(timeIntervalSince1970: 1_793_784_600))   // 2026-11-04T09:30:00Z
        #expect(status.harnesses.map(\.id) == ["claude-code", "codex", "cursor", "gemini-cli", "opencode", "zed", "warp"])
        #expect(status.newlyDetected == ["cursor"])
        #expect(status.errors.isEmpty)
        #expect(status.migrations == [IntegrationStatus.Migration(id: "claude-md", state: "proposed",
                                                                  askId: "7c1d2e3f-0000-4000-8000-000000000002",
                                                                  path: "~/.claude/CLAUDE.md")])
        let codex = try harness(status, "codex")
        #expect(codex.state == .needsOwner)
        #expect(codex.ownerSteps == [IntegrationStatus.OwnerStep(
            id: "codex-trust", title: "Trust Hook's replies hook in Codex",
            askId: "7c1d2e3f-0000-4000-8000-000000000001", state: "open")])
        #expect(codex.changes == [IntegrationStatus.Change(path: "~/.codex/AGENTS.md", what: "block instructions")])
        let mcp = try piece(codex, "mcp")
        #expect(mcp == IntegrationStatus.Piece(piece: "mcp", method: "cli", state: .installed,
                                               target: "~/.codex/config.toml", key: "mcp_servers.relay", note: nil,
                                               diffable: false, reveal: "~/.codex/config.toml"))
        let zed = try harness(status, "zed")
        #expect(try piece(zed, "replies").target == nil)
        #expect(try piece(zed, "replies").reveal == nil)
    }

    @Test func everyStateIsInTheFixture() throws {
        let status = try fixture()
        let harnessStates = Set(status.harnesses.map(\.state))
        let pieceStates = Set(status.harnesses.flatMap(\.pieces).map(\.state))
        #expect(harnessStates == Set(HarnessState.allCases))
        // foreign is shown as drifted by `status`, but a piece may still say foreign.
        #expect(pieceStates == Set(PieceState.allCases))
    }

    @Test func aMissingLastSyncIsNil() throws {
        var object = try fixtureObject()
        object["lastSync"] = NSNull()
        let status = try IntegrationStatus.decode(JSONSerialization.data(withJSONObject: object))
        #expect(status.lastSync == nil)
    }

    @Test func anUnknownExtraKeyIsIgnored() throws {
        var object = try fixtureObject()
        object["aFutureKey"] = ["anything": 1]
        var list = try #require(object["harnesses"] as? [[String: Any]])
        list[0]["anotherKey"] = "x"
        object["harnesses"] = list
        let status = try IntegrationStatus.decode(JSONSerialization.data(withJSONObject: object))
        #expect(status == (try fixture()))
    }

    @Test func anUnknownHarnessStateFailsTheDecode() throws {
        var object = try fixtureObject()
        var list = try #require(object["harnesses"] as? [[String: Any]])
        list[0]["state"] = "sleeping"
        object["harnesses"] = list
        #expect(throws: DecodingError.self) {
            try IntegrationStatus.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func anUnknownPieceStateFailsTheDecode() throws {
        var object = try fixtureObject()
        var list = try #require(object["harnesses"] as? [[String: Any]])
        var pieces = try #require(list[1]["pieces"] as? [[String: Any]])
        pieces[0]["state"] = "half-done"
        list[1]["pieces"] = pieces
        object["harnesses"] = list
        #expect(throws: DecodingError.self) {
            try IntegrationStatus.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func aDateThatIsntISO8601FailsTheDecode() throws {
        var object = try fixtureObject()
        object["lastSync"] = "yesterday"
        #expect(throws: DecodingError.self) {
            try IntegrationStatus.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func aReportAndADiffDecode() throws {
        let report = try IntegrationReport.decode(Data("""
        {"dryRun": false, "results": [
          {"harness": "codex", "piece": "mcp", "action": "install", "target": "~/.codex/config.toml",
           "outcome": "installed", "note": null},
          {"harness": "opencode", "piece": "mcp", "action": "skip", "target": "~/.config/opencode/opencode.json",
           "outcome": "skipped", "note": "edited by you"}
        ], "errors": ["a note"], "exit": 4}
        """.utf8))
        #expect(report.exit == 4)
        #expect(report.errors == ["a note"])
        #expect(report.results.map(\.outcome) == ["installed", "skipped"])
        #expect(report.results[1].note == "edited by you")
        let diff = try IntegrationDiff.decode(Data("""
        {"harness": "opencode", "piece": "mcp", "target": "~/.config/opencode/opencode.json", "diff": "--- a\\n+++ b\\n"}
        """.utf8))
        #expect(diff == IntegrationDiff(harness: "opencode", piece: "mcp", target: "~/.config/opencode/opencode.json",
                                        diff: "--- a\n+++ b\n"))
    }
}

@Suite struct IntegrationLabelTests {
    @Test func harnessLabels() {
        #expect(HarnessState.notSetUp.label == "Not set up")
        #expect(HarnessState.installed.label == "Installed")
        #expect(HarnessState.outdated.label == "Update ready")
        #expect(HarnessState.drifted.label == "Edited by you")
        #expect(HarnessState.needsOwner.label == "Needs you")
        #expect(HarnessState.blocked.label == "Needs you")
    }

    @Test func pieceLabels() {
        #expect(PieceState.notSetUp.label(harness: "Zed") == "Not set up")
        #expect(PieceState.installed.label(harness: "Zed") == "Installed")
        #expect(PieceState.accepted.label(harness: "Zed") == "Installed")
        #expect(PieceState.outdated.label(harness: "Zed") == "Update ready")
        #expect(PieceState.drifted.label(harness: "Zed") == "Edited by you")
        #expect(PieceState.foreign.label(harness: "Zed") == "Edited by you")
        #expect(PieceState.needsOwner.label(harness: "Zed") == "Needs you")
        #expect(PieceState.blocked.label(harness: "Zed") == "Needs you")
        #expect(PieceState.none.label(harness: "Zed") == "Not available in Zed")
    }

    @Test func onlyAnAcceptedPieceSaysItsEditIsKept() {
        #expect(PieceState.accepted.keptNote == "Your edit is kept. Hook asks again only if its own text changes.")
        for state in PieceState.allCases where state != .accepted {
            #expect(state.keptNote == nil)
        }
    }

    @Test func harnessActions() {
        #expect(makeHarness(.notSetUp).action == .setUp("codex"))
        #expect(makeHarness(.outdated).action == .update("codex"))
        #expect(makeHarness(.installed).action == nil)
        // Drifted has no harness action: each edited piece has its own Fix… menu.
        #expect(makeHarness(.drifted, pieces: [makePiece(.drifted)]).action == nil)
    }

    @Test func needsYouOpensTheFirstOpenAsk() {
        let steps = [
            IntegrationStatus.OwnerStep(id: "a", title: "Done already", askId: "ask-1", state: "done"),
            IntegrationStatus.OwnerStep(id: "b", title: "Not posted yet", askId: nil, state: "pending"),
            IntegrationStatus.OwnerStep(id: "c", title: "Trust it", askId: "ask-3", state: "open"),
            IntegrationStatus.OwnerStep(id: "d", title: "Reload", askId: "ask-4", state: "open"),
        ]
        #expect(makeHarness(.needsOwner, steps: steps).action == .openAsk("ask-3"))
        #expect(makeHarness(.needsOwner, steps: Array(steps.prefix(2))).action == nil)
    }

    @Test func blockedRevealsTheFirstBlockedPiece() {
        let pieces = [makePiece(.installed, reveal: "~/.zed/a"),
                      makePiece(.blocked, target: "~/.config/zed/settings.json", reveal: "~/.config/zed/settings.json"),
                      makePiece(.blocked, target: "~/.config/zed/other.json", reveal: "~/.config/zed")]
        #expect(makeHarness(.blocked, pieces: pieces).action == .reveal("~/.config/zed/settings.json"))
        // No folder to reveal: the target, else nothing.
        #expect(makeHarness(.blocked, pieces: [makePiece(.blocked, target: "~/.x/y.json", reveal: nil)]).action
                == .reveal("~/.x/y.json"))
        #expect(makeHarness(.blocked, pieces: [makePiece(.blocked, target: nil, reveal: nil)]).action == nil)
    }

    @Test func theFixturesActions() throws {
        let status = try fixture()
        #expect(try harness(status, "cursor").action == .setUp("cursor"))
        #expect(try harness(status, "gemini-cli").action == .update("gemini-cli"))
        #expect(try harness(status, "codex").action == .openAsk("7c1d2e3f-0000-4000-8000-000000000001"))
        #expect(try harness(status, "zed").action == .reveal("~/.config/zed/settings.json"))
        #expect(try harness(status, "opencode").action == nil)
        #expect(try harness(status, "claude-code").action == nil)
    }

    @Test func aHarnessActionsCommand() {
        #expect(HarnessAction.setUp("cursor").command == .sync(ifChanged: false, includeNew: false, harness: "cursor"))
        #expect(HarnessAction.update("codex").command == .sync(ifChanged: false, includeNew: false, harness: "codex"))
        #expect(HarnessAction.openAsk("ask-1").command == nil)
        #expect(HarnessAction.reveal("~/.x").command == nil)
    }
}

@Suite struct PieceFixTests {
    @Test func anEditedPieceOffersAllThree() {
        #expect(makePiece(.drifted).fixes == [.keepMine, .showDifference, .useHooks])
        #expect(makePiece(.foreign).fixes == [.keepMine, .showDifference, .useHooks])
    }

    @Test func showDifferenceNeedsADiffablePiece() {
        #expect(makePiece(.drifted, method: "cli", diffable: false).fixes == [.keepMine, .useHooks])
        #expect(makePiece(.foreign, method: "plugin", diffable: false).fixes == [.keepMine, .useHooks])
    }

    @Test func noOtherStateHasFixes() {
        for state in PieceState.allCases where state != .drifted && state != .foreign {
            #expect(makePiece(state).fixes.isEmpty, "\(state)")
        }
    }

    @Test func eachFixIsItsCommand() {
        #expect(IntegrationCommand.fix(.keepMine, harness: "codex", piece: "mcp").arguments
                == ["accept", "--harness", "codex", "--piece", "mcp", "--json"])
        #expect(IntegrationCommand.fix(.showDifference, harness: "codex", piece: "mcp").arguments
                == ["diff", "--harness", "codex", "--piece", "mcp", "--json"])
        #expect(IntegrationCommand.fix(.useHooks, harness: "codex", piece: "mcp").arguments
                == ["reinstall", "--harness", "codex", "--piece", "mcp", "--force", "--json"])
    }
}

@Suite struct IntegrationCommandTests {
    @Test func argumentsPerCommand() {
        #expect(IntegrationCommand.status.arguments == ["status", "--json"])
        #expect(IntegrationCommand.sync(ifChanged: true, includeNew: true, harness: nil).arguments
                == ["sync", "--if-changed", "--include-new", "--json"])
        #expect(IntegrationCommand.sync(ifChanged: false, includeNew: false, harness: nil).arguments == ["sync", "--json"])
        #expect(IntegrationCommand.sync(ifChanged: false, includeNew: false, harness: "zed").arguments
                == ["sync", "--harness", "zed", "--json"])
        #expect(IntegrationCommand.reinstall(harness: nil, piece: nil, force: false).arguments == ["reinstall", "--json"])
        #expect(IntegrationCommand.reinstall(harness: "zed", piece: nil, force: false).arguments
                == ["reinstall", "--harness", "zed", "--json"])
        #expect(IntegrationCommand.accept(harness: "zed", piece: nil).arguments == ["accept", "--harness", "zed", "--json"])
        #expect(IntegrationCommand.diff(harness: "zed", piece: "skill").arguments
                == ["diff", "--harness", "zed", "--piece", "skill", "--json"])
        #expect(IntegrationCommand.remove(harness: nil).arguments == ["remove", "--all", "--json"])
        #expect(IntegrationCommand.remove(harness: "zed").arguments == ["remove", "--harness", "zed", "--json"])
        #expect(IntegrationCommand.setAutoSetup(true).arguments == ["set", "auto-setup", "on", "--json"])
        #expect(IntegrationCommand.setAutoSetup(false).arguments == ["set", "auto-setup", "off", "--json"])
        #expect(IntegrationCommand.migrate(choice: "Keep CLAUDE.md as is").arguments
                == ["migrate", "claude-md", "--choose", "Keep CLAUDE.md as is", "--json"])
    }

    @Test func everyCommandEndsWithJSON() {
        let all: [IntegrationCommand] = [
            .status, .sync(ifChanged: true, includeNew: false, harness: "a"), .reinstall(harness: "a", piece: "b", force: true),
            .accept(harness: "a", piece: "b"), .diff(harness: "a", piece: nil), .remove(harness: nil),
            .setAutoSetup(true), .migrate(choice: "Apply"),
        ]
        for command in all { #expect(command.arguments.last == "--json") }
    }

    @Test func timeouts() {
        #expect(IntegrationCommand.status.timeout == 15)
        #expect(IntegrationCommand.diff(harness: "a", piece: nil).timeout == 15)
        #expect(IntegrationCommand.sync(ifChanged: true, includeNew: false, harness: nil).timeout == 120)
        #expect(IntegrationCommand.reinstall(harness: nil, piece: nil, force: false).timeout == 120)
        #expect(IntegrationCommand.remove(harness: nil).timeout == 120)
    }

    @Test func theShellLineQuotesEveryWord() {
        let line = IntegrationCommand.reinstall(harness: "zed", piece: nil, force: true)
            .shellLine(repoPath: "/Users/me/my src/$HOME's hook/", stdout: "/tmp/x/out", stderr: "/tmp/x/err")
        #expect(line == #"'/Users/me/my src/$HOME'\''s hook/bin/relay' integrations 'reinstall' '--harness' 'zed' "#
                + #"'--force' '--json' >'/tmp/x/out' 2>'/tmp/x/err'"#)
    }

    @Test func theShellLineExpandsATildeRepo() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line = IntegrationCommand.status.shellLine(repoPath: "~/src/hook", stdout: "/o", stderr: "/e")
        #expect(line.hasPrefix(Shell.quote(home + "/src/hook/bin/relay") + " integrations 'status' '--json'"))
    }

    @Test func theRelayCommandIsUnderTheRepo() {
        #expect(IntegrationCommand.relayPath(repoPath: "/opt/hook/") == "/opt/hook/bin/relay")
        #expect(IntegrationCommand.relayPath(repoPath: "  ") == nil)
        #expect(IntegrationCommand.relayPath(repoPath: nil) == nil)
        #expect(IntegrationCommand.relayPath(repoPath: "relative/hook") == nil)
    }
}

@Suite struct IntegrationOutcomeTests {
    private let json = Data(#"{"ok": true}"#.utf8)

    @Test func successAndExitFourKeepStdout() {
        #expect(IntegrationOutcome.interpret(status: 0, timedOut: false, stdout: json, stderr: "", shellOutput: "")
                == .success(json))
        #expect(IntegrationOutcome.interpret(status: 4, timedOut: false, stdout: json, stderr: "", shellOutput: "")
                == .success(json))
    }

    @Test func otherExitsGiveTheirFirstErrorLine() {
        let result = IntegrationOutcome.interpret(
            status: 1, timedOut: false, stdout: Data(),
            stderr: "usage: relay integrations …\nrelay integrations: no harness 'x' in the table\n", shellOutput: "")
        #expect(result == .failure(.failed("no harness 'x' in the table")))
        #expect(IntegrationOutcome.interpret(status: 2, timedOut: false, stdout: Data(),
                                             stderr: "relay integrations: another run holds the lock", shellOutput: "")
                == .failure(.failed("another run holds the lock")))
        // Nothing on stderr: the shell's own output, else the status.
        #expect(IntegrationOutcome.interpret(status: 127, timedOut: false, stdout: Data(), stderr: "",
                                             shellOutput: "zsh: permission denied: relay")
                == .failure(.failed("zsh: permission denied: relay")))
        #expect(IntegrationOutcome.interpret(status: 3, timedOut: false, stdout: Data(), stderr: "", shellOutput: "")
                == .failure(.failed("It stopped with status 3")))
    }

    @Test func aTimeoutIsItsOwnError() {
        #expect(IntegrationOutcome.interpret(status: 143, timedOut: true, stdout: json, stderr: "", shellOutput: "")
                == .failure(.timedOut))
    }

    @Test func emptyStdoutOnSuccessIsAnError() {
        #expect(IntegrationOutcome.interpret(status: 0, timedOut: false, stdout: Data(), stderr: "", shellOutput: "")
                == .failure(.noOutput))
    }

    @Test func errorTextsAreOneLine() {
        #expect(IntegrationError.notInstalled.text == "Hook's relay command isn't in the Hook repo folder")
        #expect(IntegrationError.timedOut.text == "relay integrations didn't finish in time")
        #expect(IntegrationError.noOutput.text == "relay integrations gave no answer")
        #expect(IntegrationError.failed("a\u{1b}[31mred").text == Sanitize.revealLine("a\u{1b}[31mred"))
    }
}

@Suite struct IntegrationScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theConstants() {
        #expect(IntegrationSchedule.launchDelay == 30)
        #expect(IntegrationSchedule.interval == 86_400)
    }

    @Test func dailyDueEdges() {
        #expect(IntegrationSchedule.dailyDue(lastSync: nil, now: now))
        #expect(!IntegrationSchedule.dailyDue(lastSync: now, now: now))
        #expect(!IntegrationSchedule.dailyDue(lastSync: now - 86_399, now: now))
        #expect(IntegrationSchedule.dailyDue(lastSync: now - 86_400, now: now))
        #expect(IntegrationSchedule.dailyDue(lastSync: now - 3 * 86_400, now: now))
        // A clock that stepped back: a sync "from the future" doesn't hold the next one off.
        #expect(!IntegrationSchedule.dailyDue(lastSync: now + 30, now: now))
        #expect(IntegrationSchedule.dailyDue(lastSync: now + 3600, now: now))
    }
}

@Suite struct IntegrationNoticeTests {
    @Test func newIdsMinusTheDismissedOnes() {
        #expect(IntegrationNotice.ids(newlyDetected: ["cursor", "zed", "pi"], dismissed: ["zed"], autoSetup: false)
                == ["cursor", "pi"])
        #expect(IntegrationNotice.ids(newlyDetected: ["cursor"], dismissed: ["cursor"], autoSetup: false).isEmpty)
        #expect(IntegrationNotice.ids(newlyDetected: [], dismissed: [], autoSetup: false).isEmpty)
    }

    @Test func automaticSetupNeedsNoNotice() {
        #expect(IntegrationNotice.ids(newlyDetected: ["cursor"], dismissed: [], autoSetup: true).isEmpty)
    }

    @Test func theFixtureOffersCursor() throws {
        let status = try fixture()
        #expect(IntegrationNotice.ids(status: status, dismissed: []) == ["cursor"])
        #expect(IntegrationNotice.names(ids: ["cursor"], status: status) == ["Cursor"])
        #expect(IntegrationNotice.names(ids: ["cursor", "nope"], status: status) == ["Cursor", "nope"])
    }

    @Test func theNoticeText() {
        #expect(IntegrationNotice.text(names: ["Cursor"]) == "Hook found Cursor. Set it up in Settings › Agents.")
        #expect(IntegrationNotice.text(names: ["Cursor", "Zed"])
                == "Hook found Cursor and Zed. Set them up in Settings › Agents.")
        #expect(IntegrationNotice.text(names: ["Cursor", "Zed", "pi"])
                == "Hook found Cursor, Zed and pi. Set them up in Settings › Agents.")
    }

    @Test func thePanelNoticeIsInfoAndOpensSettings() {
        let notice = PanelNotice.newAgents(ids: ["cursor"], names: ["Cursor"])
        #expect(notice.kind == .info)
        #expect(!notice.isTransient)
        #expect(notice.showsOnQueue)
        #expect(notice.text == "Hook found Cursor. Set it up in Settings › Agents.")
        #expect(notice.actionTitle == "Open Settings")
    }

    @Test func dismissedIdsRoundTripThroughDefaults() throws {
        let name = "integrations-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(IntegrationNotice.dismissed(in: defaults).isEmpty)
        IntegrationNotice.dismiss(["cursor", "zed"], in: defaults)
        IntegrationNotice.dismiss(["zed", "pi"], in: defaults)
        #expect(IntegrationNotice.dismissed(in: defaults) == ["cursor", "zed", "pi"])
        defaults.set(42, forKey: IntegrationNotice.defaultsKey)          // a bad value reads as none
        #expect(IntegrationNotice.dismissed(in: defaults).isEmpty)
    }
}

@MainActor private final class Log {
    var lines: [String] = []
}

@Suite struct SerialTasksTests {
    @Test @MainActor func aNewerRunWaitsForTheOlderOne() async {
        let serial = SerialTasks()
        let log = Log()
        async let first: Int = serial.run {
            log.lines.append("first start")
            try? await Task.sleep(for: .milliseconds(150))
            log.lines.append("first end")
            return 1
        }
        try? await Task.sleep(for: .milliseconds(20))
        async let second: Int = serial.run {
            log.lines.append("second start")
            return 2
        }
        let results = await [first, second]
        #expect(results == [1, 2])
        #expect(log.lines == ["first start", "first end", "second start"])
    }
}
