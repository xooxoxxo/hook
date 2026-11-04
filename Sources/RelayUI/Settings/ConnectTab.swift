import AppKit
import RelayCore
import SwiftUI

/// Settings → Connect: the agents on this Mac and what Hook set up in each, read from
/// `relay integrations status`. A plain list until Settings › Agents (list and detail)
/// replaces this tab. No inline paragraphs: every explanation is behind a "?".
public struct ConnectTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @Environment(\.panelGallery) private var gallery

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    private var agents: AgentsState { model.settings.agents }
    private var hasRepo: Bool { agents.repoPath != nil }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            if !hasRepo {
                Section("Hook repo") {
                    SettingsRow("Hook repo", help: ConnectHelp.repo) {
                        HStack(spacing: DS.Space.inline) {
                            Text("Not set").foregroundStyle(DS.Color.secondary)
                            Button("Choose Repo Folder…") { model.perform(.chooseRepoFolder) }
                        }
                    }
                }
                .environment(\.settingsSection, "Hook repo")
            } else {
                Section("On this Mac") {
                    if agents.status == nil, agents.error == nil {
                        SettingsRow("Agents") {
                            ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Reading")
                        }
                    }
                    ForEach(agents.onThisMac) { harness in
                        SettingsRow(harness.name, help: ConnectHelp.changes(harness)) { harnessControl(harness) }
                    }
                    if let error = agents.error {
                        SettingsRow("", error: error) { EmptyView() }
                    }
                }
                .environment(\.settingsSection, "On this Mac")
                Section("Setup") {
                    SettingsRow("New agents", help: ConnectHelp.autoSetup) {
                        Toggle("Set up new agents automatically", isOn: Binding(
                            get: { agents.status?.autoSetup ?? true },
                            set: { model.perform(.integration(.setAutoSetup($0))) }))
                            .toggleStyle(.checkbox)
                            .disabled(agents.status == nil || agents.busy)
                    }
                    SettingsRow("Everything", help: ConnectHelp.reinstall) {
                        HStack(spacing: DS.Space.inline) {
                            Button("Reinstall All") {
                                model.perform(.integration(.reinstall(harness: nil, piece: nil, force: false)))
                            }
                            .disabled(agents.busy)
                            if agents.busy {
                                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Working")
                            }
                        }
                    }
                    SettingsRow("MCP last call") {
                        TimelineView(.periodic(from: .now, by: DS.Timing.lastCallRefresh)) { context in
                            Text(lastCall(now: gallery.now ?? context.date))
                                .foregroundStyle(DS.Color.secondary).monospacedDigit()
                        }
                    }
                }
                .environment(\.settingsSection, "Setup")
            }
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }

    @ViewBuilder private func harnessControl(_ harness: IntegrationStatus.Harness) -> some View {
        HStack(spacing: DS.Space.inline) {
            Text(harness.state.label).foregroundStyle(DS.Color.secondary)
            switch harness.action {
            case .setUp?:
                Button("Set Up") { perform(harness.action) }.disabled(agents.busy)
            case .update?:
                Button("Update") { perform(harness.action) }.disabled(agents.busy)
            case .openAsk?:
                Button("Show Ask") { perform(harness.action) }
            case .reveal?:
                IconButton(DS.Symbol.reveal, label: "Show in Finder", help: "Show the file Hook couldn't change") {
                    perform(harness.action)
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func perform(_ action: HarnessAction?) {
        if let action { model.perform(.agentAction(action)) }
    }

    /// "—" outside This Mac only: the mailbox doesn't report MCP calls.
    private func lastCall(now: Date) -> String {
        guard model.settings.sourceKey == SourceKey.local else { return "—" }
        return ConnectInfo.lastCall(agents.lastCall, now: now)
    }
}

/// The Connect tab's "?" texts.
public enum ConnectHelp {
    public static let repo = "Hook needs its source folder to set up your agents. scripts/install.sh sets it for you."
    public static let autoSetup = "When Hook finds a new agent on this Mac, it sets up Hook's MCP server, skill, instructions and replies hook there. Off, Hook only tells you it found one."
    public static let reinstall = "Writes everything Hook installs again, in every agent it set up. A file you edited stays as you left it."

    /// What Hook changed for this harness, one path per line.
    public static func changes(_ harness: IntegrationStatus.Harness) -> String? {
        guard !harness.changes.isEmpty else { return nil }
        return "Hook changed:\n" + harness.changes.map { "\($0.path) (\($0.what))" }.joined(separator: "\n")
    }
}
