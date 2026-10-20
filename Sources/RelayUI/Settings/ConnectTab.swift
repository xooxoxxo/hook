import AppKit
import RelayCore
import SwiftUI

/// Settings → Connect (§4.8): what to paste into Claude Code on this Mac. No inline
/// heading or paragraphs (N2): every explanation is behind a "?".
public struct ConnectTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @State private var copiedSection = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelGallery) private var gallery

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    private var repo: RepoState { model.settings.repo }
    private var hasRepo: Bool { repo.repoPath != nil }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            if !hasRepo {
                Section("Relay repo") {
                    SettingsRow("Relay repo", help: ConnectHelp.repo) {
                        HStack(spacing: DS.Space.inline) {
                            Text("Not set").foregroundStyle(DS.Color.secondary)
                            Button("Choose Repo Folder…") { model.perform(.chooseRepoFolder) }
                        }
                    }
                }
                .environment(\.settingsSection, "Relay repo")
            }
            Section("Claude Code") {
                SettingsRow("MCP server", help: ConnectHelp.mcp) {
                    CodeBlock(code: repo.mcpCommand ?? ConnectInfo.mcpCommand(repoPath: "<repo>"),
                              copyLabel: "Copy the MCP command", onCopy: copy)
                }
                .disabled(!hasRepo)
                SettingsRow("Last call") {
                    TimelineView(.periodic(from: .now, by: DS.Timing.lastCallRefresh)) { context in
                        Text(lastCall(now: gallery.now ?? context.date))
                            .foregroundStyle(DS.Color.secondary).monospacedDigit()
                    }
                }
                SettingsRow("relay command") {
                    Label(repo.cliFound ? "Found" : "Not found at ~/.local/bin/relay",
                          systemImage: repo.cliFound ? DS.Symbol.statusOK : DS.Symbol.statusDown)
                        .foregroundStyle(DS.Color.secondary)
                }
                SettingsRow("CLAUDE.md", help: ConnectHelp.claudeMd,
                            error: hasRepo && !repo.claudeMdAvailable ? "docs/claude-md-section.md isn't in the repo" : nil) {
                    Button(copiedSection ? "Copied" : "Copy CLAUDE.md Section", action: copySection)
                        .contentTransition(.opacity)
                        .disabled(!hasRepo || !repo.claudeMdAvailable)
                }
                SettingsRow("Skill", help: ConnectHelp.skill, error: hasRepo ? repo.skillError : nil) { skillControl }
                    .disabled(!hasRepo)
            }
            .environment(\.settingsSection, "Claude Code")
            Section("Command line") {
                SettingsRow("Post an ask", help: ConnectHelp.cli) {
                    CodeBlock(code: ConnectInfo.cliExample(), copyLabel: "Copy the CLI example", onCopy: copy)
                }
            }
            .environment(\.settingsSection, "Command line")
            Section("Replies hook") {
                SettingsRow("settings.json", help: ConnectHelp.hook) {
                    CodeBlock(code: ConnectInfo.hookSnippet(), copyLabel: "Copy the hook settings", onCopy: copy)
                }
            }
            .environment(\.settingsSection, "Replies hook")
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }

    @ViewBuilder private var skillControl: some View {
        switch repo.skill {
        case .installed?:
            Text("Installed").foregroundStyle(DS.Color.secondary)
        case .elsewhere(let path)?:
            HStack(spacing: DS.Space.inline) {
                Text("Something else is at ~/.claude/skills/instructables").foregroundStyle(DS.Color.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        case .missing?, nil:
            Button("Install") { model.perform(.installSkill) }
        }
    }

    /// "—" outside This Mac only: the mailbox doesn't report MCP calls.
    private func lastCall(now: Date) -> String {
        guard model.settings.sourceKey == SourceKey.local else { return "—" }
        return ConnectInfo.lastCall(repo.lastCall, now: now)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySection() {
        model.perform(.copyClaudeMdSection)
        withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { copiedSection = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DS.Motion.copiedFor))
            withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { copiedSection = false }
        }
    }
}

/// The Connect tab's "?" texts (§4.8).
public enum ConnectHelp {
    public static let mcp = "Run this once in Terminal. Every Claude Code session on this Mac then has relay_post, relay_status and relay_list."
    public static let claudeMd = "Copies docs/claude-md-section.md from the repo. Paste it into ~/.claude/CLAUDE.md on this Mac."
    public static let skill = "The instructables skill teaches Claude how to write asks. Install links ~/.claude/skills/instructables to the repo's skill folder. If that path already holds something else, Relay leaves it alone."
    public static let cli = "If MCP servers are blocked here, Claude can use the CLI. The relay command posts the same asks. install.sh links it into ~/.local/bin."
    public static let hook = "Shows answers in every session. Add this to ~/.claude/settings.json. Before each prompt it prints answers given since the last one. It always exits 0, so it never blocks a prompt."
    public static let repo = "Relay needs its source folder to build these commands. scripts/install.sh sets it for you."
}
