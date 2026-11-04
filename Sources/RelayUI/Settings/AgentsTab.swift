import AppKit
import RelayCore
import SwiftUI

/// Settings › Agents (owner pick 5, direction B): the coding agents on this Mac in a sidebar,
/// what Hook set up in the selected one beside it, and a footer for every agent. The tab keeps
/// one height whichever agent is selected; both columns scroll inside it. Every explanation
/// sits behind a "?".
public struct AgentsTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    /// The selected harness, kept across Settings windows. The window is AppKit-hosted, so
    /// `@SceneStorage` would not outlive it.
    @AppStorage(AgentsPane.selectionKey) private var stored = ""
    @State private var picked: String?
    @State private var moreExpanded: Bool
    @State private var shownDiff: ShownDiff?
    @Environment(\.panelGallery) private var gallery

    /// `selection` and `moreExpanded` open the tab on a harness and with "N more supported"
    /// expanded (the gallery); the app passes neither.
    public init(model: Model, selection: String? = nil, moreExpanded: Bool = false) {
        _model = ObservedObject(wrappedValue: model)
        _picked = State(initialValue: selection)
        _moreExpanded = State(initialValue: moreExpanded)
    }

    private var agents: AgentsState { model.settings.agents }

    private var selection: Binding<String?> {
        Binding(get: { agents.selection(stored: picked ?? stored) },
                set: { id in
                    picked = id
                    if let id { stored = id }
                })
    }

    public var body: some View {
        VStack(spacing: 0) {
            if agents.repoPath == nil {
                noRepo
            } else if agents.status != nil {
                HStack(spacing: 0) {
                    sidebar.frame(width: DS.Metric.agentsSidebar)
                    Divider()
                    detail.frame(maxWidth: .infinity)
                }
                Divider()
                footer
            } else {
                reading
            }
        }
        .frame(height: DS.Metric.agentsHeight)
        .controlSize(DS.Control.form)
        .sheet(item: $shownDiff) { shown in
            PieceDiffSheet(diff: shown.diff, onClose: { shownDiff = nil }, onUseHooks: {
                shownDiff = nil
                if let piece = piece(harness: shown.diff.harness, piece: shown.diff.piece) {
                    choose(.useHooks, harness: shown.diff.harness, piece: piece)
                }
            })
        }
    }

    // MARK: States without a list

    private var noRepo: some View {
        Form {
            Section("Hook repo") {
                SettingsRow("Hook repo", help: AgentsHelp.repo) {
                    HStack(spacing: DS.Space.inline) {
                        Text("Not set").foregroundStyle(DS.Color.secondary)
                        Button("Choose Repo Folder…") { model.perform(.chooseRepoFolder) }
                    }
                }
            }
            .environment(\.settingsSection, "Hook repo")
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var reading: some View {
        if let error = agents.error {
            Form {
                Section("Agents") {
                    SettingsRow("Agents", error: error) {
                        Button("Try Again") { model.perform(.refreshAgents) }.disabled(agents.busy)
                    }
                }
                .environment(\.settingsSection, "Agents")
            }
            .formStyle(.grouped)
        } else {
            ProgressView()
                .controlSize(DS.Control.inline)
                .accessibilityLabel("Reading the agents on this Mac")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The sidebar

    private var sidebar: some View {
        let more = agents.moreSupported
        return ScrollViewReader { proxy in
            sidebarList(more: more)
                // Expanding "N more supported" scrolls it into view.
                .onChange(of: moreExpanded) { _, open in if open { reveal(more, proxy) } }
        }
    }

    private func reveal(_ more: [IntegrationStatus.Harness], _ proxy: ScrollViewProxy) {
        guard let last = more.last else { return }
        withAnimation(DS.Motion.reveal) { proxy.scrollTo(AgentsPane.moreRowID(last.id), anchor: .bottom) }
    }

    private func sidebarList(more: [IntegrationStatus.Harness]) -> some View {
        List(selection: selection) {
            Section("On this Mac") {
                ForEach(agents.onThisMac) { harness in
                    AgentSidebarRow(harness: harness).tag(harness.id as String?)
                }
            }
            if !more.isEmpty {
                Section(isExpanded: $moreExpanded) {
                    ForEach(more) { harness in
                        HStack(spacing: DS.Space.inline) {
                            HarnessMark(id: harness.id, name: harness.name, dimmed: true)
                            Text(harness.name).foregroundStyle(DS.Color.secondary).lineLimit(1)
                        }
                        .padding(.vertical, DS.Space.harnessRowV)
                        .selectionDisabled()
                        .id(AgentsPane.moreRowID(harness.id))
                    }
                } header: {
                    Text(AgentsPane.moreTitle(more.count))
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: The detail

    @ViewBuilder private var detail: some View {
        if let id = selection.wrappedValue, let harness = agents.onThisMac.first(where: { $0.id == id }) {
            AgentDetail(harness: harness, agents: agents, lastCall: lastCall,
                        perform: { model.perform($0) },
                        choose: { fix, piece in choose(fix, harness: harness.id, piece: piece) })
                .id(harness.id)
        } else {
            Text("No agents found on this Mac")
                .foregroundStyle(DS.Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "—" outside This Mac: the Pond doesn't report MCP calls.
    private var lastCall: String {
        guard model.settings.sourceKey == SourceKey.local else { return "—" }
        return ConnectInfo.lastCall(agents.lastCall, now: gallery.now ?? Date())
    }

    // MARK: The footer

    private var footer: some View {
        VStack(alignment: .trailing, spacing: DS.Space.rowLine) {
            HStack(spacing: DS.Space.inline) {
                Toggle("Set up new agents automatically", isOn: Binding(
                    get: { agents.status?.autoSetup ?? true },
                    set: { model.perform(.integration(.setAutoSetup($0))) }))
                    .toggleStyle(.checkbox)
                    .disabled(agents.busy)
                HelpButton(rowLabel: "Set up new agents automatically", text: AgentsHelp.autoSetup)
                Spacer(minLength: DS.Space.inline)
                if agents.running == AgentsPane.reinstallAll {
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Reinstalling")
                }
                Button("Reinstall All") { model.perform(.integration(AgentsPane.reinstallAll)) }
                    .disabled(agents.busy)
                HelpButton(rowLabel: "Reinstall All", text: AgentsHelp.reinstall)
            }
            .helpLabelStyle(.body)
            if let error = agents.error {
                Text(error).font(DS.Font.caption).foregroundStyle(DS.Color.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result = agents.result {
                Text(result).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.paneFooterH)
        .padding(.vertical, DS.Space.paneFooterV)
    }

    // MARK: Fix…

    private func piece(harness: String, piece: String) -> IntegrationStatus.Piece? {
        agents.status?.harnesses.first { $0.id == harness }?.pieces.first { $0.piece == piece }
    }

    private func choose(_ fix: PieceFix, harness: String, piece: IntegrationStatus.Piece) {
        AgentsPane.choose(fix, harness: harness, piece: piece, confirm: AgentsPane.runAlert,
                          send: { model.perform($0) },
                          showDifference: {
                              Task { @MainActor in
                                  if case .success(let diff) = await model.integrationDiff(harness: harness, piece: piece.piece) {
                                      shownDiff = ShownDiff(diff: diff)
                                  }
                              }
                          })
    }
}

/// The diff Show Difference opened.
struct ShownDiff: Identifiable {
    let diff: IntegrationDiff
    var id: String { AgentsState.key(harness: diff.harness, piece: diff.piece) }
}

// MARK: - Rows

/// A sidebar row: the mark, the name and its state caption, and a trailing symbol when it
/// needs action.
struct AgentSidebarRow: View {
    let harness: IntegrationStatus.Harness

    var body: some View {
        HStack(spacing: DS.Space.inline) {
            HarnessMark(id: harness.id, name: harness.name)
            VStack(alignment: .leading, spacing: DS.Space.harnessCaption) {
                Text(harness.name).lineLimit(1)
                Text(AgentsPane.caption(harness))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.rowLine)
            if harness.state.needsAction {
                let look = AgentsPane.look(harness.state)
                Image(systemName: look.symbol).foregroundStyle(look.tint).accessibilityHidden(true)
            }
        }
        .padding(.vertical, DS.Space.harnessRowV)
        .accessibilityElement(children: .combine)
    }
}

/// The selected harness: its header, the owner's step, and one row per piece.
struct AgentDetail: View {
    let harness: IntegrationStatus.Harness
    let agents: AgentsState
    let lastCall: String
    let perform: (SettingsAction) -> Void
    let choose: (PieceFix, IntegrationStatus.Piece) -> Void

    var body: some View {
        Form {
            Section { header }
            let steps = AgentsPane.yourSteps(harness, migrations: agents.status?.migrations ?? [])
            if !steps.isEmpty {
                Section("Your step") {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        LabeledContent {
                            Button("Show Ask") { if let id = step.askId { perform(.showAsk(id)) } }
                                .keyboardShortcut(index == 0 ? .defaultAction : nil)
                                .disabled(step.askId == nil)
                        } label: {
                            Label {
                                Text(step.title).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: DS.Symbol.agentNeedsYou).foregroundStyle(DS.Color.warn)
                            }
                        }
                    }
                }
            }
            Section("What Hook set up") {
                ForEach(harness.pieces, id: \.piece) { piece in
                    AgentPieceRow(harness: harness, piece: piece, agents: agents, perform: perform,
                                  choose: { choose($0, piece) })
                }
            }
            .environment(\.settingsSection, "What Hook set up")
        }
        .formStyle(.grouped)
    }

    /// Not LabeledContent: it lines the button up with the name's baseline, not the header's centre.
    private var header: some View {
        HStack(spacing: DS.Space.marker) {
            HarnessMark(id: harness.id, name: harness.name)
            VStack(alignment: .leading, spacing: DS.Space.harnessCaption) {
                HStack(spacing: DS.Space.inline) {
                    Text(harness.name).font(DS.Font.heading)
                    if let help = AgentsPane.harnessHelp(harness, lastCall: lastCall) {
                        HelpButton(rowLabel: harness.name, text: help)
                    }
                }
                .helpLabelStyle(.heading)
                AgentStateLabel(text: harness.state.label, look: AgentsPane.look(harness.state))
                    .font(DS.Font.meta)
            }
            Spacer(minLength: DS.Space.inline)
            if agents.isRunning(harness: harness.id) {
                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Working")
            } else if let action = AgentsPane.headerAction(harness) {
                Button(action.title) { perform(.agentAction(action.action)) }.disabled(agents.busy)
            }
        }
    }
}

/// One piece: its state, Fix… when the owner edited it, and the folder button on the same line.
struct AgentPieceRow: View {
    let harness: IntegrationStatus.Harness
    let piece: IntegrationStatus.Piece
    let agents: AgentsState
    let perform: (SettingsAction) -> Void
    let choose: (PieceFix) -> Void

    private var title: String { AgentsPane.pieceTitle(piece.piece) }

    var body: some View {
        SettingsRow(title, help: AgentsPane.pieceHelp(piece, harness: harness),
                    error: agents.pieceErrors[AgentsState.key(harness: harness.id, piece: piece.piece)]) {
            HStack(spacing: DS.Space.inline) {
                AgentStateLabel(text: piece.label(harness: harness.name), look: AgentsPane.look(piece.state))
                if agents.isRunning(harness: harness.id, piece: piece.piece) {
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Working")
                } else if !piece.fixes.isEmpty {
                    Menu("Fix…") {
                        ForEach(AgentsPane.fixItems(piece), id: \.title) { item in
                            Button(item.title) { choose(item.fix) }.disabled(!item.enabled)
                        }
                    }
                    .fixedSize()
                    .disabled(agents.busy)
                    .accessibilityLabel("Fix \(title)")
                }
            }
        } accessory: {
            // Hidden, not removed, so every row's state lines up on one column.
            IconButton(DS.Symbol.reveal, label: "Show \(title) in Finder") {
                if let path = piece.reveal { perform(.agentAction(.reveal(path))) }
            }
            .opacity(AgentsPane.showsFolder(piece) ? 1 : 0)
            .disabled(!AgentsPane.showsFolder(piece))
            .accessibilityHidden(!AgentsPane.showsFolder(piece))
        }
    }
}

/// A state's symbol and its words, e.g. a green tick and "Installed".
struct AgentStateLabel: View {
    let text: String
    let look: AgentsPane.Look

    var body: some View {
        HStack(spacing: DS.Space.stateLabel) {
            Image(systemName: look.symbol).imageScale(.small).foregroundStyle(look.tint).accessibilityHidden(true)
            Text(text).foregroundStyle(look.text)
        }
    }
}

// MARK: - Logic

/// What Settings › Agents shows and does, apart from the views.
enum AgentsPane {
    static let selectionKey = "relay.settings.agents.selection"
    static let reinstallAll = IntegrationCommand.reinstall(harness: nil, piece: nil, force: false)

    static func moreTitle(_ count: Int) -> String { "\(count) more supported" }
    static func moreRowID(_ id: String) -> String { "more." + id }

    /// The sidebar caption: the state, or "Installed · no replies" when the harness has no
    /// replies hook to install.
    static func caption(_ harness: IntegrationStatus.Harness) -> String {
        let noReplies = harness.pieces.contains { $0.piece == "replies" && $0.state == .none }
        return harness.state == .installed && noReplies ? "Installed · no replies" : harness.state.label
    }

    struct HeaderAction: Equatable {
        let title: String
        let action: HarnessAction
    }

    /// The detail header's button: Set Up or Update. Needs you has the "Your step" section
    /// instead, and a blocked piece its own folder button.
    static func headerAction(_ harness: IntegrationStatus.Harness) -> HeaderAction? {
        switch harness.action {
        case .setUp?: return harness.action.map { HeaderAction(title: "Set Up", action: $0) }
        case .update?: return harness.action.map { HeaderAction(title: "Update", action: $0) }
        case .openAsk?, .reveal?, nil: return nil
        }
    }

    struct YourStep: Equatable {
        let id: String
        let title: String
        let askId: String?
    }

    /// The owner steps still open, and for Claude Code the CLAUDE.md proposal while it waits.
    static func yourSteps(_ harness: IntegrationStatus.Harness,
                          migrations: [IntegrationStatus.Migration]) -> [YourStep] {
        var steps = harness.ownerSteps.filter(\.isOpen).map { YourStep(id: $0.id, title: $0.title, askId: $0.askId) }
        if harness.id == "claude-code" {
            steps += migrations.filter { $0.id == "claude-md" && $0.state == "proposed" }.map {
                YourStep(id: $0.id, title: "Move Hook's section out of CLAUDE.md", askId: $0.askId)
            }
        }
        return steps
    }

    static func pieceTitle(_ piece: String) -> String {
        switch piece {
        case "mcp": "MCP server"
        case "skill": "Skill"
        case "instructions": "Instructions"
        case "replies": "Replies hook"
        default: piece.prefix(1).uppercased() + piece.dropFirst()
        }
    }

    static func showsFolder(_ piece: IntegrationStatus.Piece) -> Bool { piece.reveal != nil }

    // MARK: Help

    /// The piece's "?": what Hook wrote, how and where, then its note.
    static func pieceHelp(_ piece: IntegrationStatus.Piece, harness: IntegrationStatus.Harness) -> String {
        var parts: [String] = []
        if piece.state == .none {
            parts.append("\(harness.name) has no hook that runs before each prompt. Hook's instructions ask the agent "
                + "to call relay_status or relay_list when a session starts and before it waits, so your answers still reach it.")
            if let note = piece.note { parts.append(sentence(note)) }
        } else {
            let how = method(piece.method)
            let place = piece.target.map { target in piece.key.map { target + " › " + $0 } ?? target }
            switch (piece.state, place) {
            case (.notSetUp, let place?): parts.append("Set Up adds it with \(how), at:\n\(place)")
            case (.notSetUp, nil): parts.append("Set Up adds it with \(how).")
            case (_, let place?): parts.append("Hook set it up with \(how), at:\n\(place)")
            case (_, nil): parts.append("Hook set it up with \(how).")
            }
            if let kept = piece.state.keptNote {
                parts.append(kept)
            } else if let note = piece.note {
                parts.append(sentence(note))
            }
        }
        if harness.verified == "docs-only" { parts.append("Set up from its docs; not tested on a Mac yet.") }
        return parts.joined(separator: "\n\n")
    }

    /// The header's "?": every path Hook changed, and for Claude Code the MCP server's last call.
    static func harnessHelp(_ harness: IntegrationStatus.Harness, lastCall: String) -> String? {
        var parts: [String] = []
        if !harness.changes.isEmpty {
            parts.append("Hook changed:\n" + harness.changes.map { "\($0.path) (\($0.what))" }.joined(separator: "\n"))
        }
        if harness.id == "claude-code" { parts.append("MCP last call: \(lastCall)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func method(_ method: String) -> String {
        switch method {
        case "plugin": "a plugin Hook renders for this Mac"
        case "cli": "the agent's own command"
        case "file": "a file Hook owns"
        case "copy": "a copy Hook owns"
        case "block": "a marked block in your file"
        case "key": "one key in its settings"
        case "owner": "a step only you can do"
        default: method
        }
    }

    /// "edited by you" → "Edited by you."
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        let capital = first.isLowercase ? first.uppercased() + trimmed.dropFirst() : trimmed
        return ".!?".contains(capital.last ?? ".") ? capital : capital + "."
    }

    // MARK: Fix…

    struct FixItem: Equatable {
        let fix: PieceFix
        let title: String
        let enabled: Bool
    }

    /// Keep Mine (disabled when the edit is in a file the agent no longer reads), Show Difference
    /// (disabled when there is no text to compare) and Use Hook's…, for a piece marked Edited by
    /// you; nothing for any other.
    static func fixItems(_ piece: IntegrationStatus.Piece) -> [FixItem] {
        let fixes = piece.fixes
        guard !fixes.isEmpty else { return [] }
        return [FixItem(fix: .keepMine, title: "Keep Mine", enabled: fixes.contains(.keepMine)),
                FixItem(fix: .showDifference, title: "Show Difference", enabled: fixes.contains(.showDifference)),
                FixItem(fix: .useHooks, title: "Use Hook's…", enabled: true)]
    }

    struct ReplaceAlert: Equatable {
        let message: String
        let info: String
    }

    static func replaceAlert(target: String?) -> ReplaceAlert {
        guard let target else {
            return ReplaceAlert(message: "Replace your edits?", info: "Hook saves a copy first.")
        }
        let name = (target as NSString).lastPathComponent
        return ReplaceAlert(message: "Replace your edits to \(target)?", info: "Hook saves a copy as \(name).bak first.")
    }

    /// Runs one Fix… item. Use Hook's sends nothing unless `confirm` (the alert) says Replace.
    static func choose(_ fix: PieceFix, harness: String, piece: IntegrationStatus.Piece,
                       confirm: (ReplaceAlert) -> Bool, send: (SettingsAction) -> Void, showDifference: () -> Void) {
        switch fix {
        case .keepMine:
            send(.integration(.fix(.keepMine, harness: harness, piece: piece.piece)))
        case .showDifference:
            showDifference()
        case .useHooks:
            guard confirm(replaceAlert(target: piece.target)) else { return }
            send(.integration(.fix(.useHooks, harness: harness, piece: piece.piece)))
        }
    }

    /// The stock alert for Use Hook's…: Replace or Cancel.
    @MainActor static func runAlert(_ alert: ReplaceAlert) -> Bool {
        let panel = NSAlert()
        panel.alertStyle = .warning
        panel.messageText = alert.message
        panel.informativeText = alert.info
        panel.addButton(withTitle: "Replace")
        panel.addButton(withTitle: "Cancel")
        return panel.runModal() == .alertFirstButtonReturn
    }

    // MARK: Looks

    struct Look {
        let symbol: String
        let tint: AnyShapeStyle
        let text: AnyShapeStyle
    }

    private static func look(_ symbol: String, _ tint: some ShapeStyle,
                             text: some ShapeStyle = DS.Color.secondary) -> Look {
        Look(symbol: symbol, tint: AnyShapeStyle(tint), text: AnyShapeStyle(text))
    }

    static func look(_ state: HarnessState) -> Look {
        switch state {
        case .installed: look(DS.Symbol.agentInstalled, DS.Color.done)
        case .outdated: look(DS.Symbol.agentUpdate, DS.Color.accent)
        case .drifted: look(DS.Symbol.agentEdited, DS.Color.secondary)
        case .needsOwner: look(DS.Symbol.agentNeedsYou, DS.Color.warn, text: DS.Color.warnText)
        case .blocked: look(DS.Symbol.agentBlocked, DS.Color.warn, text: DS.Color.warnText)
        case .notSetUp: look(DS.Symbol.agentNotSetUp, DS.Color.secondary)
        }
    }

    static func look(_ state: PieceState) -> Look {
        switch state {
        case .installed, .accepted: look(DS.Symbol.agentInstalled, DS.Color.done)
        case .outdated: look(DS.Symbol.agentUpdate, DS.Color.accent)
        case .drifted, .foreign: look(DS.Symbol.agentEdited, DS.Color.secondary)
        case .needsOwner: look(DS.Symbol.agentNeedsYou, DS.Color.warn, text: DS.Color.warnText)
        case .blocked: look(DS.Symbol.agentBlocked, DS.Color.warn, text: DS.Color.warnText)
        case .notSetUp: look(DS.Symbol.agentNotSetUp, DS.Color.secondary)
        case .none: look(DS.Symbol.agentNone, DS.Color.tertiary, text: DS.Color.tertiary)
        }
    }
}

/// Settings › Agents' and the setup window's "?" texts.
public enum AgentsHelp {
    public static let repo = "Hook needs its source folder to set up your agents. scripts/install.sh sets it for you."
    public static let autoSetup = "When Hook finds a coding agent it hasn't set up, it adds Hook's MCP server, the instructables skill, its instructions and, where the agent has one, the replies hook. Off, Hook tells you it found one instead."
    public static let reinstall = "Writes everything again from this version of Hook, in every agent it set up. A file you edited stays as you left it, marked Edited by you."
}
