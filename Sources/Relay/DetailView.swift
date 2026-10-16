import AppKit
import SwiftUI
import RelayCore
import RelayUI

/// One ask: header with progress, text, a tickable timeline, links,
/// reply, and the Done/Skip bar. Every ask string goes through Sanitize via
/// `line`, `prose` or `CodeBlock`.
struct DetailView: View {
    @ObservedObject private var store: Store
    private let id: String
    @State private var ticks: Set<Int> = []
    @State private var draft = ""
    @State private var sentChoice: String?
    @State private var sentText = false
    @FocusState private var editorFocused: Bool

    init(store: Store, id: String) {
        _store = ObservedObject(wrappedValue: store)
        self.id = id
    }

    var body: some View {
        Group {
            if let ask = currentAsk {
                content(ask)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            ticks = Ticks.load(.standard, sourceKey: store.sourceKey, id: id)
        }
    }

    /// The fetched detail, or just the list item until the detail arrives.
    private var currentAsk: DetailModel? {
        if let detail = store.detail(for: id) { return DetailModel.make(detail) }
        if let item = store.item(for: id) { return DetailModel.make(item: item, events: []) }
        return nil
    }

    private func content(_ ask: DetailModel) -> some View {
        VStack(spacing: 0) {
            header(ask)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    intro(ask)
                    timeline(ask)
                    if !ask.links.isEmpty {
                        linksSection(ask.links)
                    }
                    if let reply = ask.reply {
                        replySection(reply)
                    }
                    if !ask.ownerReplies.isEmpty {
                        repliesList(ask.ownerReplies)
                    }
                    if let command = ask.origin?.resumeCommand {
                        resumeSection(command)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            bottomBar(ask)
        }
    }

    // MARK: Header and text

    /// One calm row: back chevron, project, urgency, progress.
    private func header(_ ask: DetailModel) -> some View {
        HStack(spacing: 6) {
            Button {
                store.select(nil)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .help("Back to the queue (Esc)")
            .accessibilityLabel("Back to the queue")
            MonogramView(project: ask.project, size: 18)
            Text(verbatim: ask.project.isEmpty ? "—" : line(ask.project))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            UrgencyPill(urgency: ask.urgency)
                .fixedSize()
            Spacer(minLength: 8)
            if !ask.nodes.isEmpty {
                Text(verbatim: "\(ticks.filter { $0 < ask.nodes.count }.count) of \(ask.nodes.count) done")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        // 9 pt leading puts the chevron glyph (centred in its 22 pt frame) on the
        // 16 pt content edge, in line with the title below.
        .padding(.leading, 9)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        // Drag the header to move the panel to another edge or display.
        .background(PanelDragHandle())
    }

    @ViewBuilder private func intro(_ ask: DetailModel) -> some View {
        Text(verbatim: line(ask.title))
            .font(.system(size: 17, weight: .semibold))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .padding(.bottom, 4)
        if let origin = ask.origin {
            // Where the ask came from; the full folder, host and session on hover.
            Text(verbatim: "From " + line(origin.summary))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(origin.helpLines.map(line).joined(separator: "\n"))
                .padding(.bottom, 6)
        }
        if let why = ask.why {
            Text(verbatim: prose(why))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
        ForEach(Array(ask.notes.enumerated()), id: \.offset) { _, note in
            Text(verbatim: prose(note))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
        Spacer().frame(height: 12)
    }

    // MARK: Timeline

    private func timeline(_ ask: DetailModel) -> some View {
        let current = ask.nodes.first { !ticks.contains($0.index) }?.index
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(ask.nodes, id: \.index) { node in
                TimelineNode(
                    node: node,
                    ticked: ticks.contains(node.index),
                    current: node.index == current,
                    isLast: node.index == ask.nodes.count - 1,
                    toggle: { toggle(node.index) })
            }
        }
    }

    private func toggle(_ index: Int) {
        if ticks.contains(index) {
            ticks.remove(index)
        } else {
            ticks.insert(index)
        }
        Ticks.save(.standard, sourceKey: store.sourceKey, id: id, ticks: ticks)
    }

    // MARK: Links and reply

    private func linksSection(_ links: [LinkRef]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Links")
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                if let url = webURL(link.url) {
                    WebLink(label: link.label, url: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// Choices send "choice: <choice>" and leave the ask open;
    /// free text uses a 2–6 line editor. Reply works on closed asks too.
    private func replySection(_ reply: ReplySpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: prose(reply.prompt))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let choices = reply.choices, !choices.isEmpty {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    HStack(spacing: 8) {
                        Button {
                            sendChoice(choice)
                        } label: {
                            Text(verbatim: line(choice))
                        }
                        .disabled(store.busyID != nil)
                        if sentChoice == choice {
                            Text("Sent").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .frame(height: editorHeight)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    .onChange(of: draft) { _, text in
                        if !text.isEmpty { sentText = false }
                    }
                HStack {
                    if sentText {
                        Text("Sent").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Send", action: sendDraft)
                        .keyboardShortcut(editorFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busyID != nil)
                        .help("Send (⌘↩ while typing)")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Color.accentColor.opacity(0.06)))
        .padding(.bottom, 12)
    }

    /// 2 to 6 lines, growing with the draft's line breaks.
    private var editorHeight: CGFloat {
        let lines = draft.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(6, max(2, lines))) * 17 + 8
    }

    private func repliesList(_ replies: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Your replies")
            ForEach(Array(replies.enumerated()), id: \.offset) { _, text in
                Text(verbatim: prose(text))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The exact command to get back to the session that posted the ask.
    private func resumeSection(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Back to the session")
            CodeBlock(code: command, lang: "shell")
        }
        .padding(.top, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func sendChoice(_ choice: String) {
        let id = self.id
        Task {
            if await store.reply(id, text: "choice: \(choice)") { sentChoice = choice }
        }
    }

    private func sendDraft() {
        let id = self.id
        let text = draft
        Task {
            if await store.reply(id, text: text) {
                draft = ""
                sentText = true
            }
        }
    }

    // MARK: Bottom bar

    private func bottomBar(_ ask: DetailModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.actionError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ask.isOpen {
                HStack {
                    Button("Skip") { finish(.declined, title: ask.title) }
                    Spacer()
                    Button("Done") { finish(.done, title: ask.title) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(editorFocused ? nil : KeyboardShortcut(.return, modifiers: .command))
                        .help("Done (⌘↩)")
                }
                .disabled(store.busyID != nil)
            } else {
                Text(verbatim: Self.closedLine(by: ask.closedBy, at: ask.closedAt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Done or Skip as the owner, held back for Undo; the panel goes back to the queue.
    private func finish(_ verdict: Verdict, title: String) {
        store.close(id, verdict, title: title)
    }

    /// "Closed by the session · 11 Oct 2026 at 14:32" (local time).
    static func closedLine(by actor: String?, at stamp: String?) -> String {
        var text: String
        switch actor {
        case "session": text = "Closed by the session"
        case "owner": text = "Closed by you"
        default: text = "Closed"
        }
        if let stamp, let date = Timestamp.date(stamp) {
            text += " · " + date.formatted(date: .abbreviated, time: .shortened)
        }
        return text
    }
}

/// One timeline node: a tick circle on the vertical line, then the step.
private struct TimelineNode: View {
    let node: DetailModel.Node
    let ticked: Bool
    let current: Bool
    let isLast: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                marker
            }
            .buttonStyle(.plain)
            .help(ticked ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(Text(verbatim: (ticked ? "Done: " : "Not done: ") + line(node.action)))
            VStack(alignment: .leading, spacing: 5) {
                if node.isVerify {
                    placeLabel("Verify")
                } else if let place = node.place {
                    placeLabel(line(place))
                }
                Text(verbatim: line(node.action))
                    .strikethrough(ticked, color: .secondary)
                    .foregroundStyle(ticked ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = node.detail {
                    // Longer instructions: plain wrapped prose, like `why`.
                    Text(verbatim: prose(detail))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = node.code {
                    CodeBlock(code: code, lang: node.lang)
                }
                if let raw = node.url, let url = webURL(raw) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(verbatim: linkTitle("Open", url) + " ↗")
                    }
                    .controlSize(.small)
                    .help(line(url.absoluteString))
                }
                if let expect = node.expect {
                    Text(verbatim: "Expect: " + prose(expect))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 12)
        .overlay(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 26)
                    .padding(.bottom, 2)
                    .padding(.leading, 10.5)
            }
        }
    }

    private var marker: some View {
        Text(verbatim: ticked || node.isVerify ? "✓" : "\(node.index + 1)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(markerText)
            .frame(width: 22, height: 22)
            .background(Circle().fill(markerFill))
            .overlay(Circle().strokeBorder(markerStroke, lineWidth: current && !ticked ? 2 : 1.5))
            .contentShape(Circle())
    }

    private var markerFill: Color {
        if ticked { return .green }
        if node.isVerify { return Color.green.opacity(0.15) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var markerText: Color {
        if ticked { return .white }
        if node.isVerify { return .green }
        return current ? .accentColor : .primary
    }

    private var markerStroke: Color {
        if ticked || node.isVerify { return .clear }
        return current ? .accentColor : Color.primary.opacity(0.18)
    }

    private func placeLabel(_ text: String) -> some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }
}

/// Code with a language label and Copy, dark in both appearances. What is shown
/// is exactly what Copy puts on the pasteboard (hidden characters revealed).
/// Plain text soft-wraps; other languages keep their lines and scroll sideways.
struct CodeBlock: View {
    let code: String
    let lang: String?
    @State private var copied = false

    var body: some View {
        let shown = Sanitize.reveal(code, as: .code)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: line(lang ?? ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", action: copy)
                    .controlSize(.small)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.top, 5)
            if shown.hidden {
                Text(verbatim: "Hidden characters shown as ⟨U+…⟩ — check before running")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
            if CodeWrap.shouldWrap(lang: lang) {
                codeText(shown.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    codeText(shown.text)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.codeRadius).fill(Theme.codeBackground))
        .environment(\.colorScheme, .dark)
    }

    private func codeText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.codeFont)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 9)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Sanitize.copyText(code), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
