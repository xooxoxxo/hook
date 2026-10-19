import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Settings → Connect: what to paste into Claude Code on this Mac, the
/// skill link, and whether the CLI and MCP are in use. The commands come from
/// `repoPath`, which install.sh writes.
struct ConnectTab: View {
    static let noRepoNote = "Run scripts/install.sh from the repo to set these up"

    @ObservedObject private var model: AppModel
    @State private var skill: ConnectInfo.SkillState = .missing
    @State private var section: String?
    @State private var cliFound = false
    @State private var skillError: String?
    @State private var copiedSection = false

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// `$HOME`, like LaunchAgent, so a manual check can point it at a temp folder.
    private static var home: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var repoPath: String? {
        guard let path = model.config?.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Let Claude Code on this Mac send you asks")
                .font(.headline)

            if let repoPath {
                block("Add Relay to Claude Code (MCP)",
                      help: "Run this once in Terminal. Every Claude Code session on this Mac then has relay_post, relay_status and relay_list.") {
                    CodeBlock(code: ConnectInfo.mcpCommand(repoPath: repoPath), copyLabel: "Copy the MCP command",
                              onCopy: { Self.copy($0) })
                }
            } else {
                Text(Self.noRepoNote)
                    .foregroundStyle(.secondary)
            }

            block("CLI",
                  help: "If MCP servers are blocked here, Claude can use the CLI. The relay command posts the same asks. install.sh links it into ~/.local/bin.") {
                CodeBlock(code: ConnectInfo.cliExample(), copyLabel: "Copy the CLI example", onCopy: { Self.copy($0) })
            }

            block("Replies hook (optional)",
                  help: "Shows answers in every session. Add this to ~/.claude/settings.json. Before each prompt it prints answers given since the last one. It always exits 0, so it never blocks a prompt.") {
                CodeBlock(code: ConnectInfo.hookSnippet(), copyLabel: "Copy the hook settings", onCopy: { Self.copy($0) })
            }

            if repoPath != nil {
                sectionRow
                skillRow
            }

            Divider()
            statusRows
        }
        .settingsPage()
        .onAppear {
            refresh()
            model.setLastSeenPolling(true)
        }
        .onDisappear {
            model.setLastSeenPolling(false)
        }
        .onChange(of: model.config) { _, _ in
            refresh()
        }
    }

    // MARK: Rows

    private func block<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                HelpButton(help)
            }
            content()
        }
    }

    private var sectionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Tell Claude when to use it:")
                Button(copiedSection ? "Copied" : "Copy CLAUDE.md section", action: copySection)
                    .disabled(section == nil)
                HelpButton("Copies docs/claude-md-section.md from the repo. Paste it into ~/.claude/CLAUDE.md on this Mac.")
            }
            if section == nil {
                Text("docs/claude-md-section.md isn't in the repo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var skillRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Skill:")
                switch skill {
                case .installed:
                    Text("Installed")
                case .missing:
                    Button("Install", action: installSkill)
                case .elsewhere:
                    Text("Another skill is there")
                }
                HelpButton("The instructables skill teaches Claude how to write asks. Install links ~/.claude/skills/instructables to the repo's skill folder. If that path already holds something else, Relay leaves it alone.")
            }
            if case .elsewhere(let path) = skill {
                Text(verbatim: path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let skillError {
                Text(verbatim: skillError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cliFound
                 ? "relay command: found at ~/.local/bin/relay"
                 : "relay command: not found at ~/.local/bin/relay")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("MCP last call: \(mcpLastCall(now: context.date))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func mcpLastCall(now: Date) -> String {
        guard case .local = model.resolvedSource else { return "—" }
        return ConnectInfo.lastCall(model.lastSeen["mcp"], now: now)
    }

    private func refresh() {
        let home = Self.home
        cliFound = ConnectInfo.cliInstalled(home: home)
        if let repoPath {
            skill = ConnectInfo.skillState(home: home, repoPath: repoPath)
            section = ConnectInfo.claudeMdSection(repoPath: repoPath)
        } else {
            skill = .missing
            section = nil
        }
    }

    private func installSkill() {
        guard let repoPath else { return }
        do {
            try ConnectInfo.installSkill(home: Self.home, repoPath: repoPath)
            skillError = nil
        } catch {
            skillError = error.localizedDescription
        }
        refresh()
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySection() {
        guard let section else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(section, forType: .string)
        copiedSection = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedSection = false
        }
    }
}
