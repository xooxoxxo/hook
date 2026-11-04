import AppKit
import Foundation
import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

private typealias Harness = IntegrationStatus.Harness
private typealias Piece = IntegrationStatus.Piece

private func piece(_ name: String, _ state: PieceState, method: String = "key", diffable: Bool = false,
                   target: String? = "~/.config/agent/settings.json", reveal: String? = "~/.config/agent",
                   note: String? = nil) -> Piece {
    Piece(piece: name, method: method, state: state, target: target, key: nil, note: note, diffable: diffable,
          reveal: reveal)
}

private func harness(_ id: String, _ name: String, _ state: HarnessState, detected: Bool = true, managed: Bool = true,
                     pieces: [Piece] = [], steps: [IntegrationStatus.OwnerStep] = [],
                     verified: String = "pending") -> Harness {
    Harness(id: id, name: name, detected: detected, managed: managed, state: state, verified: verified,
            pieces: pieces, ownerSteps: steps, changes: [])
}

@Suite @MainActor struct AgentsTabTests {
    private var mac: AgentsState { SettingsFixtures.agentsMac }

    // MARK: The sidebar

    @Test func theSidebarListsWhatIsOnThisMacClaudeCodeFirstThenTheRestByName() {
        #expect(mac.onThisMac.map(\.id) == ["claude-code", "codex", "copilot-cli", "cursor", "gemini-cli", "opencode",
                                            "pi", "vscode-copilot", "zed"])
        #expect(mac.moreSupported.map(\.id) == ["amp", "antigravity", "cline", "devin", "factory", "goose", "junie",
                                                "kiro", "warp"])
        #expect(AgentsPane.moreTitle(mac.moreSupported.count) == "9 more supported")
        #expect(AgentsPane.moreTitle(1) == "1 more supported")
    }

    @Test func aHarnessHookSetUpButCanNoLongerFindStaysOnThisMac() {
        let state = AgentsState(status: IntegrationStatus(harnesses: [
            harness("pi", "pi", .installed, detected: false, managed: true),
            harness("amp", "Amp", .notSetUp, detected: false, managed: false),
        ]))
        #expect(state.onThisMac.map(\.id) == ["pi"])
        #expect(state.moreSupported.map(\.id) == ["amp"])
    }

    @Test func theSelectionDefaultsToTheFirstRowNeedingAction() {
        // Claude Code is installed; Codex needs the owner.
        #expect(mac.defaultSelection == "codex")
        let calm = AgentsState(status: IntegrationStatus(harnesses: [
            harness("zed", "Zed", .installed), harness("claude-code", "Claude Code", .installed),
        ]))
        #expect(calm.defaultSelection == "claude-code")
        #expect(AgentsState().defaultSelection == nil)
        // Not set up is no action row: Set Up is offered, nothing is wrong.
        let fresh = AgentsState(status: IntegrationStatus(harnesses: [
            harness("claude-code", "Claude Code", .installed), harness("cursor", "Cursor", .notSetUp, managed: false),
        ]))
        #expect(fresh.defaultSelection == "claude-code")
    }

    @Test func aStoredSelectionWinsWhileItIsStillOnThisMac() {
        #expect(mac.selection(stored: "zed") == "zed")
        #expect(mac.selection(stored: "warp") == "codex")          // in "more supported": not selectable
        #expect(mac.selection(stored: "gone") == "codex")
        #expect(mac.selection(stored: nil) == "codex")
        #expect(mac.selection(stored: "") == "codex")
    }

    @Test func rowsNeedingActionAreUpdateEditedAndNeedsYou() {
        #expect(HarnessState.allCases.filter(\.needsAction) == [.outdated, .drifted, .needsOwner, .blocked])
    }

    @Test func theCaptionIsTheStateOrInstalledWithoutReplies() {
        let zed = harness("zed", "Zed", .installed, pieces: [piece("mcp", .installed), piece("replies", .none)])
        #expect(AgentsPane.caption(zed) == "Installed · no replies")
        let codex = harness("codex", "Codex", .needsOwner, pieces: [piece("replies", .needsOwner)])
        #expect(AgentsPane.caption(codex) == "Needs you")
        #expect(AgentsPane.caption(harness("x", "X", .outdated)) == "Update ready")
        #expect(AgentsPane.caption(harness("x", "X", .drifted)) == "Edited by you")
        #expect(AgentsPane.caption(harness("x", "X", .notSetUp)) == "Not set up")
    }

    // MARK: The detail

    @Test func theHeaderButtonIsSetUpOrUpdateAndHiddenForNeedsYou() {
        #expect(AgentsPane.headerAction(harness("cursor", "Cursor", .notSetUp))
            == AgentsPane.HeaderAction(title: "Set Up", action: .setUp("cursor")))
        #expect(AgentsPane.headerAction(harness("gemini-cli", "Gemini CLI", .outdated))
            == AgentsPane.HeaderAction(title: "Update", action: .update("gemini-cli")))
        let step = IntegrationStatus.OwnerStep(id: "t", title: "Trust it", askId: "a1", state: "open")
        #expect(AgentsPane.headerAction(harness("codex", "Codex", .needsOwner, steps: [step])) == nil)
        #expect(AgentsPane.headerAction(harness("zed", "Zed", .blocked, pieces: [piece("mcp", .blocked)])) == nil)
        #expect(AgentsPane.headerAction(harness("x", "X", .installed)) == nil)
        #expect(AgentsPane.headerAction(harness("x", "X", .drifted)) == nil)
    }

    @Test func yourStepListsOpenOwnerStepsAndTheClaudeMigration() {
        let codex = mac.onThisMac.first { $0.id == "codex" }!
        let steps = AgentsPane.yourSteps(codex, migrations: mac.status?.migrations ?? [])
        #expect(steps.map(\.title) == ["Trust Hook's replies hook in Codex"])
        #expect(steps.first?.askId == SettingsFixtures.codexAskID)
        let claude = mac.onThisMac.first { $0.id == "claude-code" }!
        #expect(AgentsPane.yourSteps(claude, migrations: []).isEmpty)
        let proposed = IntegrationStatus.Migration(id: "claude-md", state: "proposed", askId: "m1", path: "~/.claude/CLAUDE.md")
        #expect(AgentsPane.yourSteps(claude, migrations: [proposed])
            == [AgentsPane.YourStep(id: "claude-md", title: "Move Hook's section out of CLAUDE.md", askId: "m1")])
        let applied = IntegrationStatus.Migration(id: "claude-md", state: "applied", askId: "m1")
        #expect(AgentsPane.yourSteps(claude, migrations: [applied]).isEmpty)
        // The migration belongs to Claude Code only.
        #expect(AgentsPane.yourSteps(codex, migrations: [proposed]).count == 1)
        let done = IntegrationStatus.OwnerStep(id: "t", title: "Trust it", askId: "a1", state: "done")
        #expect(AgentsPane.yourSteps(harness("codex", "Codex", .installed, steps: [done]), migrations: []).isEmpty)
    }

    @Test func eachPieceHasItsOwnStateLabel() {
        #expect(AgentsPane.pieceTitle("mcp") == "MCP server")
        #expect(AgentsPane.pieceTitle("skill") == "Skill")
        #expect(AgentsPane.pieceTitle("instructions") == "Instructions")
        #expect(AgentsPane.pieceTitle("replies") == "Replies hook")
        #expect(piece("mcp", .accepted).label(harness: "Zed") == "Installed")
        #expect(piece("mcp", .drifted).label(harness: "Zed") == "Edited by you")
        #expect(piece("mcp", .foreign).label(harness: "Zed") == "Edited by you")
        #expect(piece("replies", .none).label(harness: "Zed") == "Not available in Zed")
        #expect(piece("mcp", .needsOwner).label(harness: "Zed") == "Needs you")
    }

    @Test func thePieceHelpSaysWhatHookWroteAndKeepsNotesBehindTheQuestionMark() {
        let zed = harness("zed", "Zed", .installed, verified: "docs-only")
        let kept = piece("instructions", .accepted, method: "file", target: "~/.claude/rules/hook.md")
        let help = AgentsPane.pieceHelp(kept, harness: zed)
        #expect(help.contains("~/.claude/rules/hook.md"))
        #expect(help.contains("Your edit is kept. Hook asks again only if its own text changes."))
        #expect(help.contains("Set up from its docs; not tested on a Mac yet"))
        let keyed = Piece(piece: "mcp", method: "key", state: .installed, target: "~/.config/zed/settings.json",
                          key: "context_servers.relay", note: nil, diffable: false, reveal: nil)
        #expect(AgentsPane.pieceHelp(keyed, harness: harness("zed", "Zed", .installed))
            .contains("~/.config/zed/settings.json › context_servers.relay"))
        #expect(!AgentsPane.pieceHelp(keyed, harness: harness("zed", "Zed", .installed)).contains("docs"))
        let none = AgentsPane.pieceHelp(piece("replies", .none, method: "none", target: nil, note: "Zed has no per-prompt hook"),
                                        harness: zed)
        #expect(none.contains("relay_status"))
        #expect(none.contains("Zed has no per-prompt hook"))
    }

    @Test func claudeCodesQuestionMarkCarriesTheMCPLastCall() {
        let claude = mac.onThisMac.first { $0.id == "claude-code" }!
        #expect(AgentsPane.harnessHelp(claude, lastCall: "2 min ago")?.contains("MCP last call: 2 min ago") == true)
        let codex = mac.onThisMac.first { $0.id == "codex" }!
        #expect(AgentsPane.harnessHelp(codex, lastCall: "2 min ago")?.contains("MCP last call") != true)
    }

    @Test func theFolderButtonIsHiddenWithoutAPathToReveal() {
        #expect(AgentsPane.showsFolder(piece("mcp", .installed, reveal: "~/.codex")))
        #expect(!AgentsPane.showsFolder(piece("mcp", .installed, reveal: nil)))
    }

    // MARK: Fix…

    @Test func theFixMenuOffersKeepMineShowDifferenceAndUseHooks() {
        let diffable = piece("mcp", .drifted, diffable: true)
        #expect(AgentsPane.fixItems(diffable) == [
            AgentsPane.FixItem(fix: .keepMine, title: "Keep Mine", enabled: true),
            AgentsPane.FixItem(fix: .showDifference, title: "Show Difference", enabled: true),
            AgentsPane.FixItem(fix: .useHooks, title: "Use Hook's…", enabled: true),
        ])
        // A plugin or CLI piece has no text to compare: Show Difference stays, disabled.
        let plain = piece("replies", .drifted, method: "cli", diffable: false)
        #expect(AgentsPane.fixItems(plain).map(\.enabled) == [true, false, true])
        #expect(AgentsPane.fixItems(piece("skill", .foreign, method: "copy", diffable: true)).count == 3)
        for state in PieceState.allCases where state != .drifted && state != .foreign {
            #expect(AgentsPane.fixItems(piece("mcp", state, diffable: true)).isEmpty, "\(state)")
        }
    }

    @Test func keepMineSendsAcceptWithTheHarnessAndPiece() {
        var sent: [SettingsAction] = []
        var asked = 0
        AgentsPane.choose(.keepMine, harness: "opencode", piece: piece("mcp", .drifted),
                          confirm: { _ in asked += 1; return true }, send: { sent.append($0) }, showDifference: {})
        #expect(sent == [.integration(.accept(harness: "opencode", piece: "mcp"))])
        #expect(asked == 0)
    }

    @Test func useHooksSendsNothingUntilTheAlertsReplace() {
        var sent: [SettingsAction] = []
        var alerts: [AgentsPane.ReplaceAlert] = []
        let edited = piece("mcp", .drifted, target: "~/.config/opencode/opencode.json")
        AgentsPane.choose(.useHooks, harness: "opencode", piece: edited,
                          confirm: { alerts.append($0); return false }, send: { sent.append($0) }, showDifference: {})
        #expect(sent.isEmpty)
        #expect(alerts == [AgentsPane.ReplaceAlert(message: "Replace your edits to ~/.config/opencode/opencode.json?",
                                                   info: "Hook saves a copy as opencode.json.bak first.")])
        AgentsPane.choose(.useHooks, harness: "opencode", piece: edited,
                          confirm: { _ in true }, send: { sent.append($0) }, showDifference: {})
        #expect(sent == [.integration(.reinstall(harness: "opencode", piece: "mcp", force: true))])
    }

    @Test func showDifferenceOpensTheSheetAndSendsNothing() {
        var sent: [SettingsAction] = []
        var shown = 0
        AgentsPane.choose(.showDifference, harness: "opencode", piece: piece("mcp", .drifted, diffable: true),
                          confirm: { _ in true }, send: { sent.append($0) }, showDifference: { shown += 1 })
        #expect(sent.isEmpty && shown == 1)
    }

    @Test func aPieceShowsProgressOnlyWhileItsOwnCommandRuns() {
        var state = mac
        state.running = .accept(harness: "opencode", piece: "mcp")
        #expect(state.isRunning(harness: "opencode", piece: "mcp"))
        #expect(!state.isRunning(harness: "opencode", piece: "skill"))
        state.running = .sync(ifChanged: false, includeNew: false, harness: "cursor")
        #expect(state.isRunning(harness: "cursor"))
        #expect(!state.isRunning(harness: "opencode"))
    }

    // MARK: The diff sheet

    @Test func diffLinesAreTintedByKind() {
        #expect(DiffLineKind.of("--- hook") == .header)
        #expect(DiffLineKind.of("+++ ~/.config/opencode/opencode.json") == .header)
        #expect(DiffLineKind.of("@@ -1,3 +1,3 @@") == .hunk)
        #expect(DiffLineKind.of("+  \"relay\": {}") == .added)
        #expect(DiffLineKind.of("-  \"relay\": {}") == .removed)
        #expect(DiffLineKind.of("   context") == .context)
        #expect(DiffLineKind.of("") == .context)
    }

    // MARK: Tabs, the result line and Welcome

    @Test func theStoredConnectTabOpensAgents() {
        #expect(SettingsTabID(stored: "connect") == .agents)
        #expect(SettingsTabID(stored: "agents") == .agents)
        #expect(SettingsTabID(stored: "queue") == .queue)
        #expect(SettingsTabID(stored: "nope") == nil)
        #expect(SettingsTabID.agents.title == "Agents")
    }

    @Test func reinstallAllSaysHowManyEditsStayed() throws {
        func report(_ outcomes: [String]) throws -> IntegrationReport {
            let results = outcomes.map { #"{"harness":"zed","piece":"mcp","action":"own","target":null,"outcome":"\#($0)"}"# }
            return try IntegrationReport.decode(Data(#"{"dryRun":false,"results":[\#(results.joined(separator: ","))],"errors":[],"exit":0}"#.utf8))
        }
        #expect(try report(["written", "unchanged"]).reinstallLine == "Reinstalled.")
        #expect(try report(["written", "skipped"]).reinstallLine == "Reinstalled. 1 change you made stays as you left it.")
        #expect(try report(["skipped", "skipped", "failed"]).reinstallLine
            == "Reinstalled. 2 changes you made stay as you left them. 1 couldn't be written.")
    }

    @Test func theWelcomePageIsDoneWhenNoDetectedHarnessIsNotSetUp() {
        #expect(!mac.allSetUp)                                         // Cursor is found and not set up
        var done = mac
        done.status?.harnesses = mac.status!.harnesses.map { h in
            var copy = h
            if copy.state == .notSetUp && copy.detected { copy.state = .installed }
            return copy
        }
        #expect(done.allSetUp)                                         // Needs you still counts as set up
    }

    // MARK: Layout

    @Test func theTabKeepsOneHeightWhicheverHarnessIsSelected() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var heights: Set<CGFloat> = []
            for id in ["claude-code", "codex", "opencode", "zed", "cursor"] {
                let view = AgentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
                    config: SettingsFixtures.localConfig, agents: SettingsFixtures.agentsMac)), selection: id)
                let host = NSHostingView(rootView: view.frame(width: DS.Metric.settingsWidth))
                host.appearance = NSAppearance(named: appearance)
                heights.insert(host.fittingSize.height)
            }
            #expect(heights == [DS.Metric.agentsHeight], "\(appearance.rawValue)")
        }
    }

    @Test func withNoRepoTheTabKeepsItsHeightToo() {
        let view = AgentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
            config: RelayConfig(source: .local), agents: AgentsState())))
        #expect(NSHostingView(rootView: view.frame(width: DS.Metric.settingsWidth)).fittingSize.height
            == DS.Metric.agentsHeight)
    }
}
