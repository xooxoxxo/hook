import RelayCore
import RelayUI
import SwiftUI

/// One captioned sample on the components sheet.
struct Sample {
    let caption: String
    let view: AnyView

    init<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) {
        self.caption = caption
        view = AnyView(content())
    }
}

struct SheetSection {
    let title: String
    let samples: [Sample]
}

/// The sheet's sections in reading order, one per group of components.
@MainActor func sheetSections() -> [SheetSection] {
    [typeRamp(), controls(), rows(), headers(), bars(), codeAndLinks(), steps(), reply(), states()]
}

@MainActor func typeRamp() -> SheetSection {
    SheetSection(title: "Type ramp", samples: [
        Sample("DS.Font") {
            VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                Text("listTitle · headline").font(DS.Font.listTitle)
                Text("askTitle · title3 semibold").font(DS.Font.askTitle)
                Text("heading · headline").font(DS.Font.heading)
                Text("body · body").font(DS.Font.body)
                Text("currentAction · headline").font(DS.Font.currentAction)
                Text("meta · subheadline").font(DS.Font.meta)
                Text("prose · callout").font(DS.Font.prose)
                Text("code · callout monospaced").font(DS.Font.code)
                Text("caption · caption").font(DS.Font.caption)
                Text("welcomeTitle · title2 semibold").font(DS.Font.welcomeTitle)
            }
        },
    ])
}

@MainActor func controls() -> SheetSection {
    SheetSection(title: "Controls", samples: [
        Sample("IconButton · normal, tinted, disabled") {
            HStack(spacing: DS.Space.inline) {
                IconButton(DS.Symbol.refresh, label: "Refresh", help: "Refresh (⌘R)") {}
                IconButton(DS.Symbol.filterOn, label: "Group and filter", tint: DS.Color.accent) {}
                IconButton(DS.Symbol.next, label: "Next ask", help: "Next ask (⌘↓)") {}.disabled(true)
            }
        },
        Sample("HelpButton") { HStack { Text("Presence"); HelpButton(rowLabel: "Presence", text: "Hook marks you away when the screen locks.") } },
        Sample("TrailingDisclosureStyle · collapsed") {
            DisclosureGroup(isExpanded: .constant(false)) { Text("Hidden body") } label: { Text("Done step") }
                .disclosureGroupStyle(.trailing)
        },
        Sample("TrailingDisclosureStyle · expanded") {
            DisclosureGroup(isExpanded: .constant(true)) { Text("The body shows under the label.") } label: { Text("Done step") }
                .disclosureGroupStyle(.trailing)
        },
    ])
}

/// A one-off sidebar List, so rows render with real List chrome.
struct MiniList<Content: View>: View {
    let height: CGFloat
    var selection: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        List(selection: .constant(selection)) { content }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .cardListHighlightOff()
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, DS.Metric.rowMinHeight)
            .frame(height: height)
    }
}

let rowInsets = EdgeInsets(top: DS.Space.rowInsetV, leading: DS.Space.rowInsetH,
                           bottom: DS.Space.rowInsetV, trailing: DS.Space.rowInsetH)

let cardInsets = EdgeInsets(top: DS.Space.cardInsetV, leading: DS.Space.cardInsetH,
                            bottom: DS.Space.cardInsetV, trailing: DS.Space.cardInsetH)

let sampleRows: [AskRowModel] = [
    AskRowModel(id: "r1", title: "Renew the staging certificate and the deploy key", project: "Acme", urgency: .now,
                created: "2026-10-16T06:40:00Z", summary: .steps(done: 2, total: 8)),
    AskRowModel(id: "r2", title: "Choose the backup region", project: "Acme", urgency: .today,
                created: "2026-10-16T00:40:00Z", summary: .steps(done: 0, total: 1)),
    AskRowModel(id: "r3", title: "Review the onboarding checklist", project: "Acme", urgency: .today,
                created: "2026-10-15T23:40:00Z", summary: .steps(done: 0, total: 4), hasDraft: true),
    AskRowModel(id: "r4", title: "Send the release notes draft", project: "Relay", urgency: .whenever,
                created: "2026-10-15T09:40:00Z", summary: .steps(done: 0, total: 2)),
    AskRowModel(id: "r5", title: "Pick a colour for the dashboard theme", project: "Northwind", urgency: .today,
                created: "2026-10-16T04:40:00Z", summary: .choose(3)),
    AskRowModel(id: "r6", title: "Send the invoice number from the receipt", project: "Atlas", urgency: .unknown("soon"),
                created: "2026-10-15T09:40:00Z", summary: .reply),
]

let sampleClosed = AskRowModel(id: "c1", title: "Store the API key", project: "Acme", urgency: .today,
                               created: "2026-10-16T05:40:00Z", summary: .none,
                               closed: ClosedInfo(status: "done", closedBy: "owner", completedAt: "2026-10-16T06:40:00Z"))

@MainActor func rows() -> SheetSection {
    /// The card on the gallery clock; `urgencyInHeader` as under an Urgency section header.
    func askRow(_ row: AskRowModel, selected: String? = nil, urgencyInHeader: Bool = false) -> some View {
        MiniList(height: 104, selection: selected) {
            AskRow(row: row, age: RelativeAge.text(created: row.created, now: GalleryFixtures.now),
                   compactAge: RelativeAge.compact(created: row.created, now: GalleryFixtures.now),
                   urgencyInHeader: urgencyInHeader, onShowOnlyProject: {})
                .listRowInsets(cardInsets)
                .listRowBackground(CardBackground(selected: row.id == selected))
                .tag(row.id)
        }
    }
    return SheetSection(title: "Rows", samples: [
        Sample("UrgencyLabel · now, today, whenever, unknown") {
            HStack(spacing: DS.Space.section) {
                UrgencyLabel(.now); UrgencyLabel(.today); UrgencyLabel(.whenever); UrgencyLabel(.unknown("soon"))
            }
            .font(DS.Font.meta)
        },
        Sample("SectionHeader · urgency and project, empty name") {
            MiniList(height: 120) {
                Section { EmptyView() } header: { SectionHeader(name: "Now", count: 1) }
                Section { EmptyView() } header: { SectionHeader(name: "Acme", count: 3) }
                Section { EmptyView() } header: { SectionHeader(name: "", count: 1) }
            }
        },
        Sample("MonogramBadge · palette, no project, closed") {
            HStack(spacing: DS.Space.inline) {
                ForEach(["Acme", "Relay", "Northwind", "Atlas", "Bluebird", "Fjord", "Kestrel", "Central Time"], id: \.self) {
                    MonogramBadge(project: $0)
                }
                MonogramBadge(project: "")
                MonogramBadge(project: "Acme", quiet: true)
            }
        },
        Sample("AskRow · now with progress") { askRow(sampleRows[0]) },
        Sample("AskRow · now, under an Urgency header") { askRow(sampleRows[0], urgencyInHeader: true) },
        Sample("AskRow · today, one step") { askRow(sampleRows[1]) },
        Sample("AskRow · whenever (no urgency mark)") { askRow(sampleRows[3]) },
        Sample("AskRow · selected") { askRow(sampleRows[1], selected: "r2") },
        Sample("AskRow · draft pending") { askRow(sampleRows[2]) },
        Sample("AskRow · choice summary") { askRow(sampleRows[4]) },
        Sample("AskRow · reply summary, unknown urgency") { askRow(sampleRows[5]) },
        Sample("ClosedAskRow") {
            MiniList(height: 96) {
                ClosedAskRow(row: sampleClosed, closedLine: "Done 3 h ago", onReopen: {}, onShowOnlyProject: {})
                    .listRowInsets(cardInsets)
                    .listRowBackground(CardBackground(selected: false, quiet: true))
            }
        },
        Sample("ClosedGroupHeader · collapsed, expanded") {
            MiniList(height: 72) {
                Section { EmptyView() } header: { ClosedGroupHeader(count: 2, expanded: .constant(false)) }
                Section { EmptyView() } header: { ClosedGroupHeader(count: 2, expanded: .constant(true)) }
            }
        },
        Sample("EmptyListLine · plain, filtered") {
            MiniList(height: 190) {
                EmptyListLine(project: nil, onShowAll: {})
                EmptyListLine(project: "Acme", onShowAll: {})
            }
        },
    ])
}

let sampleProjects = [MenuProject(name: "Acme", open: 3), MenuProject(name: "Northwind", open: 1), MenuProject(name: "Relay", open: 1)]
let longProject = "Quarterly planning for the public launch of the pricing page"

@MainActor func headers() -> SheetSection {
    func list(_ title: String, refreshing: Bool = false, filter: String? = nil, hidden: HiddenCount = .zero) -> some View {
        ListHeaderBar(title: title, refreshing: refreshing, updated: "09:40", grouping: .constant(.project),
                      filter: .constant(filter), projects: sampleProjects, hidden: hidden,
                      onRefresh: {}, onHide: {}, onDock: { _ in })
    }
    func detail(previous: Neighbour, next: Neighbour) -> some View {
        DetailHeaderBar(project: "Acme", urgency: .now, age: "3 h ago", previous: previous, next: next,
                        onBack: {}, onPrevious: {}, onNext: {}, onHide: {}, onDock: { _ in })
    }
    return SheetSection(title: "Headers", samples: [
        Sample("ListHeaderBar · idle") { list("5 waiting") },
        Sample("ListHeaderBar · manual refresh running") { list("5 waiting", refreshing: true) },
        Sample("ListHeaderBar · filtered, 2 hidden") { list("3 waiting", filter: "Acme", hidden: HiddenCount(total: 2, now: 0)) },
        Sample("ListHeaderBar · filtered, hidden now") { list("1 waiting", filter: "Relay", hidden: HiddenCount(total: 4, now: 1)) },
        Sample("FilterRow · long name") { FilterRow(project: longProject, hidden: HiddenCount(total: 4, now: 0), onClear: {}) },
        Sample("DetailHeaderBar · middle") { detail(previous: .ask("p"), next: .ask("n")) },
        Sample("DetailHeaderBar · at the end") { detail(previous: .ask("p"), next: .end) },
        Sample("DetailHeaderBar · outside the filter") { detail(previous: .outsideFilter, next: .outsideFilter) },
    ])
}

@MainActor func bars() -> SheetSection {
    let soon = Date().addingTimeInterval(8)
    func status(_ symbol: StatusSymbol, _ text: String) -> some View {
        StatusBar(symbol: symbol, text: text, onSettings: {}) { Text("Updated 09:40") }
    }
    let actionError = "Couldn't send Done for “Send the release notes draft”. The mailbox didn't answer within 10 seconds."
    // StatusBar's popover wrapper, so the samples have the popover's padding and width.
    func details(_ status: PanelStatus, updated: String = "") -> some View {
        StatusDetails(status: status, updated: updated, onTryAgain: {}, onSettings: {}, onShowConfig: {})
            .padding(DS.Space.popover)
            .frame(width: DS.Metric.helpWidth)
    }
    let configError = PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: true, loadedOnce: true,
                                                    configNote: "pollSeconds: must be a whole number from 5 to 3600"))
    let listenerDown = PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: true, loadedOnce: true,
                                                     listenerNote: "Port 47823 is in use by another app"))
    return SheetSection(title: "Bars", samples: [
        Sample("UndoBar · one") { UndoBar(undo: UndoInfo(verdict: .done, title: "Rotate the mailbox token", deadline: soon, more: 0), onUndo: {}) },
        Sample("UndoBar · several") { UndoBar(undo: UndoInfo(verdict: .declined, title: "Rotate the mailbox token", deadline: soon, more: 1), onUndo: {}) },
        Sample("UndoBar · sending (quit)") {
            UndoBar(undo: UndoInfo(verdict: .done, title: "Rotate the mailbox token", deadline: soon, more: 1), sending: true, onUndo: {})
        },
        Sample("StatusBar · ready") { status(.ok, "Mailbox · ready") },
        Sample("StatusBar · connecting") { status(.connecting, "Mailbox · connecting…") },
        Sample("StatusBar · offline") { status(.down, "Mailbox · offline") },
        Sample("StatusBar · not set up") { status(.notSetUp, "Not set up") },
        Sample("StatusBar · away") { status(.away, "Away · Mailbox · ready") },
        Sample("StatusDetails · updated") { details(readyStatus, updated: "10:42") },
        Sample("StatusDetails · offline") { details(offlineStatus(loadedOnce: true), updated: "09:22") },
        Sample("StatusDetails · config error") { details(configError) },
        Sample("StatusDetails · listener") { details(listenerDown) },
        Sample("ActionBar · open") { ActionBar(mode: .open(.done), onSkip: {}, onPrimary: {}, onReopen: {}) },
        Sample("ActionBar · warning, unsent answer") {
            ActionBar(mode: .warning(.answer, busy: false), answers: ActionBarAnswers(caption: UnsentKind.answer.caption),
                      onSkip: {}, onPrimary: {}, onReopen: {})
        },
        Sample("ActionBar · warning, unsent reply") {
            ActionBar(mode: .warning(.reply, busy: false), answers: ActionBarAnswers(caption: UnsentKind.reply.caption),
                      onSkip: {}, onPrimary: {}, onReopen: {})
        },
        Sample("ActionBar · warning, sending") {
            ActionBar(mode: .warning(.answer, busy: true), answers: ActionBarAnswers(caption: UnsentKind.answer.caption),
                      onSkip: {}, onPrimary: {}, onReopen: {})
        },
        Sample("ActionBar · busy") { ActionBar(mode: .busy(.done), onSkip: {}, onPrimary: {}, onReopen: {}) },
        Sample("ActionBar · closed") { ActionBar(mode: .closed("Done by you · 16 Oct, 06:12"), onSkip: {}, onPrimary: {}, onReopen: {}) },
        Sample("Notice · error") { Notice(kind: .error, text: "Couldn't save the queue. The disk is full.", actionTitle: nil, onAction: {}, onDismiss: {}) },
        Sample("Notice · error with action") { Notice(kind: .error, text: actionError, actionTitle: "Retry", onAction: {}, onDismiss: {}) },
        Sample("Notice · info") { Notice(kind: .info, text: "Settings changed, so the queue reloaded.", actionTitle: nil, onAction: {}, onDismiss: {}) },
        Sample("Notice · info with action") { Notice(kind: .info, text: "Offline · showing asks from 09:22", actionTitle: "Try Again", onAction: {}, onDismiss: {}) },
    ])
}

@MainActor func codeAndLinks() -> SheetSection {
    let store = "ssh-keygen -t ed25519 -f ~/.ssh/acme_deploy -C deploy@example.com"
    func open(_ raw: String) -> some View {
        OpenLink(title: LinkDisplay.stepTitle(raw) ?? raw, url: URL(string: raw)!)
    }
    return SheetSection(title: "Code and links", samples: [
        Sample("CodeBlock · normal") { CodeBlock(code: store, copyLabel: "Copy the command for step 5", lang: "bash", onCopy: { _ in }) },
        Sample("CodeBlock · copied") { CodeBlock(code: store, copyLabel: "Copy the command for step 5", copied: true, onCopy: { _ in }) },
        Sample("CodeBlock · hidden characters") { CodeBlock(code: "echo token\u{200B}-ok", copyLabel: "Copy the verify command", onCopy: { _ in }) },
        Sample("CodeBlock · long line wraps") { CodeBlock(code: String(repeating: "curl -s https://api.example.com/v1/items | ", count: 4) + "jq .", copyLabel: "Copy the command for step 2", onCopy: { _ in }) },
        Sample("OpenLink · web") { open("https://www.example.com/oauth/apps") },
        Sample("OpenLink · non-ASCII host") { open("https://xn--bcher-kva.example.com/apps") },
        Sample("RefusedLink · not a web address") { RefusedLink(text: LinkDisplay.refusedText(label: nil), raw: "ftp://files.example.com/brief.pdf") },
        Sample("Link row") { OpenLink(title: LinkDisplay.linkTitle(label: "API docs", url: "https://api.example.com/v2/docs"), url: URL(string: "https://api.example.com/v2/docs")!) },
        Sample("ExpectLine") { ExpectLine("token-ok") },
    ])
}

let sampleStep1 = StepContent(action: "Create the release folder", place: "Mac terminal",
                              code: "mkdir -p ~/src/acme/release", expect: "The command prints nothing")
let sampleParent = StepContent(action: "Register the Acme app", place: "Developer portal")
let sampleSubs = [
    StepContent(action: "Click New App, then Start empty", url: "https://developer.example.com/apps"),
    StepContent(action: "Name it Acme and pick your team"),
    StepContent(action: "Under Permissions, add the read scope", code: "items:read", lang: "text"),
]
let sampleStep4 = StepContent(action: "Create an access token", place: "Developer portal",
                              detail: "Click New Token. Name it Acme and set it to expire in 90 days, then save. Treat the token like a password.",
                              url: "https://developer.example.com/tokens")
let sampleBlocking = StepContent(action: "Point the domain at the new host", place: "DNS provider",
                                 detail: "Change the A record to the new address.", blocking: true,
                                 warning: "Wait for DNS to update before going on.")
let sampleVerify = StepContent(action: "Check the release folder exists", place: "Mac terminal",
                               code: "test -d ~/src/acme/release && echo folder-ok", expect: "folder-ok")

@MainActor func steps() -> SheetSection {
    func step(_ c: StepContent, _ level: StepLevel, _ state: StepState, expanded: Bool = false, readOnly: Bool = false) -> some View {
        StepView(content: c, level: level, state: state, total: 6, readOnly: readOnly, expanded: .constant(expanded),
                 onToggle: {}, onCopy: { _ in })
    }
    func parent(_ states: [StepState], expanded: Bool = false, readOnly: Bool = false) -> some View {
        ParentStepView(content: sampleParent, number: 2, total: 6, children: sampleSubs, childPaths: ["2.1", "2.2", "2.3"],
                       childStates: states, readOnly: readOnly,
                       expanded: .constant(expanded), childExpanded: { _ in .constant(false) },
                       onToggleParent: {}, onToggleChild: { _ in }, onCopy: { _ in })
    }
    return SheetSection(title: "Steps", samples: [
        Sample("StepView · done, collapsed") { step(sampleStep1, .top(1), .done) },
        Sample("StepView · done, expanded") { step(sampleStep1, .top(1), .done, expanded: true) },
        Sample("StepView · current") { step(sampleStep4, .top(4), .current) },
        Sample("StepView · todo") { step(sampleStep1, .top(5), .todo) },
        Sample("ParentStepView · holds the current sub-step") { parent([.done, .current, .todo]) },
        Sample("ParentStepView · done, collapsed") { parent([.done, .done, .done]) },
        Sample("ParentStepView · done, expanded") { parent([.done, .done, .done], expanded: true) },
        Sample("StepView · sub-step read-only") { step(sampleSubs[2], .sub(2, 2), .todo, readOnly: true) },
        Sample("StepView · verify todo") { step(sampleVerify, .verify, .todo) },
        Sample("StepView · verify current") { step(sampleVerify, .verify, .current) },
        Sample("StepView · verify done") { step(sampleVerify, .verify, .done) },
        Sample("StepView · read-only") { step(sampleStep4, .top(4), .todo, readOnly: true) },
        Sample("StepView · blocking, current") { step(sampleBlocking, .top(3), .current) },
        Sample("StepView · locked") {
            StepView(content: sampleStep1, level: .top(4), state: .todo, total: 6, readOnly: false,
                     expanded: .constant(false), lockText: "Finish step 3 first", onToggle: {}, onCopy: { _ in })
        },
        Sample("ParentStepView · read-only") { parent([.done, .todo, .todo], readOnly: true) },
    ])
}

/// ReplyBox needs a FocusState; the gallery holds one per sample.
struct ReplySample: View {
    let text: String
    let state: ReplyBoxState
    var showHeading = true
    @FocusState private var focused: Bool

    var body: some View {
        ReplyBox(prompt: "Paste the ticket ID from the tracker (starts with C)", text: .constant(text), state: state,
                 showHeading: showHeading, isFocused: $focused, onSend: {}, onRetry: {})
    }
}

@MainActor func reply() -> SheetSection {
    let choices = ["Europe", "North America"]
    let origin = AskOrigin(from: Origin(session: "1b2c3d4e-0000-4000-8000-000000000001", host: "example-mac", cwd: "/work/acme"))!
    func choice(picked: Int?, sent: Set<Int>, latest: Int?) -> some View {
        ChoiceGroup(prompt: "Which region should the backups use?", choices: choices, picked: .constant(picked), sent: sent,
                    latestSent: latest, sending: false, onSend: {})
    }
    return SheetSection(title: "Reply", samples: [
        Sample("ReplyBox · empty") { ReplySample(text: "", state: .idle) },
        Sample("ReplyBox · typing") { ReplySample(text: "C0123ABCDEF", state: .idle) },
        Sample("ReplyBox · sending") { ReplySample(text: "C0123ABCDEF", state: .sending) },
        Sample("ReplyBox · sent") { ReplySample(text: "", state: .sent(at: "09:40")) },
        Sample("ReplyBox · failed") { ReplySample(text: "C0123ABCDEF", state: .failed(reason: "The mailbox didn't answer within 10 seconds.")) },
        Sample("ChoiceGroup · none picked") { choice(picked: nil, sent: [], latest: nil) },
        Sample("ChoiceGroup · picked") { choice(picked: 0, sent: [], latest: nil) },
        Sample("ChoiceGroup · sent") { choice(picked: 0, sent: [0], latest: 0) },
        Sample("OptionRows · step single") {
            OptionRows(prompt: "Which target?", options: ["Staging", "Production"], selected: [1], onPick: { _ in })
        },
        Sample("OptionRows · step multi") {
            OptionRows(prompt: "Which flags?", options: ["Search", "Exports", "Dark mode"], multi: true,
                       selected: [0, 2], onPick: { _ in })
        },
        Sample("RepliesList") {
            RepliesList([ReplyLine(id: 1, text: "You chose: Europe", time: "09:12"), ReplyLine(id: 2, text: "C0123ABCDEF", time: "09:31")])
        },
        Sample("Reply anyway · expanded") {
            DisclosureGroup("Reply anyway", isExpanded: .constant(true)) {
                VStack(alignment: .leading, spacing: DS.Space.inline) {
                    Text("The session may have finished. It sees this only if it checks replies.")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                    ReplySample(text: "", state: .idle, showHeading: false)
                }
            }
        },
        Sample("FromDisclosure · collapsed") { FromDisclosure(origin: origin, expanded: .constant(false), onCopy: { _ in }) },
        Sample("FromDisclosure · expanded") { FromDisclosure(origin: origin, expanded: .constant(true), onCopy: { _ in }) },
    ])
}

/// Three panel-wide columns; section i goes to column i % 3.
struct ComponentsSheet: View {
    let sections: [SheetSection]

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.section) {
            ForEach(0..<3, id: \.self) { column in
                VStack(alignment: .leading, spacing: DS.Space.section) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        if index % 3 == column { sectionView(section) }
                    }
                }
                .frame(width: DS.Metric.panelWidth, alignment: .topLeading)
            }
        }
        .padding(DS.Space.section)
    }

    private func sectionView(_ section: SheetSection) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.step) {
            Text(section.title).font(DS.Font.heading)
            ForEach(Array(section.samples.enumerated()), id: \.offset) { _, sample in
                VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                    Text(sample.caption).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                    sample.view
                }
            }
        }
    }
}

@MainActor func states() -> SheetSection {
    func state(_ kind: StateKind) -> some View { StateView(kind, actions: .none).frame(height: 220) }
    return SheetSection(title: "States and Settings rows", samples: [
        Sample("StateView · loading") { state(.loading(source: "Mailbox", stillTrying: false)) },
        Sample("StateView · loading, still trying") { state(.loading(source: "Mailbox", stillTrying: true)) },
        Sample("StateView · empty") { state(.empty(updated: "09:40")) },
        Sample("StateView · empty, filtered") { state(.emptyFiltered(project: "Atlas", updated: "09:40")) },
        Sample("StateView · offline") { state(.offline(title: "Can't reach the mailbox", reason: "The mailbox didn't answer within 10 seconds.")) },
        Sample("StateView · not set up") { state(.notSetUp) },
        Sample("StateView · not found") { state(.notFound(canShowClosed: true)) },
        // MailboxFields needs the Settings width (fieldWide); the settings-queue and welcome scenes show it.
        Sample("SettingsRow · help, none, error") {
            Form {
                Section("Shortcut") {
                    SettingsRow("Show or hide Hook", help: "Click the field, then press the new keys.",
                                error: "That key can't be used. Pick a letter, a digit, Space, ` or F1–F12.") {
                        ShortcutField(label: "⌃⌥⌘R", onBegin: {}, onRecord: { _ in }, onCancel: {}, onClear: {})
                    }
                    SettingsRow("Appearance") {
                        Picker("Appearance", selection: .constant(0)) { Text("System").tag(0) }.labelsHidden().fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 260)
        },
    ])
}

@MainActor let componentScenes: [GalleryScene] = [
    GalleryScene(
        name: "components",
        size: .wide(width: 3 * DS.Metric.panelWidth + 4 * DS.Space.section, height: nil),
        standIn: true,
        view: { AnyView(ComponentsSheet(sections: sheetSections())) }),
]
