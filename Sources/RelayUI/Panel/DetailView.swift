import AppKit
import RelayCore
import SwiftUI

/// One ask. A ScrollView with the header pinned on top and the Undo and
/// action bars pinned below: title, steps, reply and your replies, links and From.
struct DetailView<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelGallery) private var gallery
    @AppStorage("relay.detail.fromExpanded") private var storedFromExpanded = false
    @FocusState private var replyFocused: Bool
    @State private var nodeFrames: [String: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    /// The measured height of the bottom bars (undo bar + action bar); 0 until measured.
    @State private var barHeight: CGFloat = 0
    /// False until restoreAnchor has issued its scroll: frame reports before that must not
    /// overwrite the saved anchor, whichever of onAppear and onPreferenceChange runs first.
    @State private var restored = false

    /// The title block's anchor; never a step path (digits or "verify").
    private static var titleAnchor: String { "title" }

    init(model: Model, id: String) {
        _model = ObservedObject(wrappedValue: model)
        self.id = id
    }

    /// The ask is in Recently closed, so "Show Closed Ask" can open it.
    static func isRecentlyClosed(_ id: String, in queue: QueueSnapshot) -> Bool {
        queue.closed.contains { $0.id == id }
    }

    /// Closed: its text and Reopen. The Done warning while it shows (busy while Send & Done
    /// sends). Open: the primary (Flow.primaryAction), busy while sending.
    static func actionMode(_ snapshot: DetailSnapshot) -> ActionBarMode {
        if let closedText = snapshot.closedText { return .closed(closedText) }
        if snapshot.doneWarning, let kind = snapshot.unsentKind { return .warning(kind, busy: snapshot.busy) }
        return snapshot.busy ? .busy(snapshot.primary) : .open(snapshot.primary)
    }

    /// The bar caption for an open ask: the warning's "You have an unsent answer" while it
    /// shows, else the unanswered count; a failed answers send replaces it.
    static func answers(_ snapshot: DetailSnapshot) -> ActionBarAnswers {
        guard snapshot.closedText == nil else { return .none }
        var failure: String?
        if case .failed(let reason)? = snapshot.answerState { failure = reason }
        let warning = snapshot.doneWarning ? snapshot.unsentKind?.caption : nil
        return ActionBarAnswers(caption: warning ?? snapshot.unansweredCaption, failure: failure)
    }

    /// The ask a header chevron opens; nil at the ends and outside the filter (disabled).
    static func target(_ neighbour: Neighbour) -> String? {
        if case .ask(let id) = neighbour { return id }
        return nil
    }

    /// An open ask with a free-text reply whose steps are only informational (no step, sub-step
    /// or verify has code, a url or sub-steps) focuses its field when it opens.
    /// With choices there is no field to focus. An empty sub-step list is no sub-steps.
    static func focusesReplyOnOpen(_ snapshot: DetailSnapshot) -> Bool {
        guard snapshot.closedText == nil, let detail = snapshot.model, let reply = detail.reply,
              (reply.choices ?? []).isEmpty else { return false }
        return Flow.flattened(detail.nodes).allSatisfy {
            $0.content.code == nil && $0.content.url == nil && $0.children.isEmpty
        }
    }

    var body: some View {
        if let snapshot = model.detail(id) {
            frame(snapshot)
                // Runs on appear (cached detail) and again when a lazily loaded detail turns the
                // predicate true; polls that keep it true don't re-fire, so a field left stays left.
                .onChange(of: Self.focusesReplyOnOpen(snapshot), initial: true) { _, focuses in
                    if focuses { replyFocused = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: .relayFocusReply)) { _ in
                    focusReply()
                }
        } else {
            notFound
        }
    }

    /// ⌘L: an answered reply opens for Change first, then its field takes focus.
    private func focusReply() {
        guard let snapshot = model.detail(id), snapshot.model?.reply != nil else { return }
        if snapshot.closedText == nil,
           AnswerEditing.showsReplyAnswer(replies: snapshot.replies, editing: model.editingReply.contains(id),
                                          draft: model.drafts[id], pick: model.pendingChoice[id]) {
            model.changeReply(id)
            DispatchQueue.main.async { replyFocused = true }
        } else {
            replyFocused = true
        }
    }

    private var notFound: some View {
        VStack(spacing: 0) {
            PanelHeader(onDock: { model.shell.dock($0) }) {
                IconButton(DS.Symbol.back, label: "Back to the queue", help: "Back to the queue (Esc)") { model.back() }
                Spacer()
                // Esc goes back in detail, so Hide names ⌘W: one key never has two meanings.
                IconButton(DS.Symbol.hide, label: "Hide Hook", help: DetailHeaderBar.hideHelp) { model.shell.hide() }
            }
            StateView(.notFound(canShowClosed: Self.isRecentlyClosed(id, in: model.queue)),
                      actions: PanelStateMapping.actions(model, closedID: id))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The gallery renders full height without a ScrollView (offscreen, a ScrollView has no
    /// height of its own); the app always scrolls.
    @ViewBuilder private func frame(_ snapshot: DetailSnapshot) -> some View {
        if gallery.fullHeight == true {
            VStack(spacing: 0) {
                header(snapshot)
                content(snapshot)
                bottomBars(snapshot)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    content(snapshot)
                }
                .coordinateSpace(name: detailScrollSpace)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
                })
                .onPreferenceChange(NodeFramesKey.self) { frames in
                    // Some SDKs mark this closure @Sendable; it always runs on the main thread.
                    MainActor.assumeIsolated {
                        nodeFrames = frames
                        noteAnchor(frames, order: [Self.titleAnchor] + Flow.flattened(snapshot.model?.nodes ?? []).map(\.path))
                    }
                }
                .onAppear { restoreAnchor(proxy) }
                .onChange(of: snapshot.current) { _, current in scrollToCurrent(current, proxy: proxy) }
                .safeAreaInset(edge: .top, spacing: 0) { header(snapshot) }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBars(snapshot) }
            }
        }
    }

    /// The visible band of the ScrollView: below the pinned header, above the bottom bars
    /// as measured (the designed action bar height until they are).
    private var visibleTop: CGFloat { DS.Metric.header }
    private var visibleBottom: CGFloat {
        Flow.visibleBottom(viewportHeight: viewportHeight, barHeight: barHeight, fallback: DS.Metric.actionBar)
    }

    /// Saves the top visible node as this ask's anchor (memory only); writes only on change,
    /// so scrolling doesn't republish the model every frame. The title block comes first in
    /// `order`: while it is the top visible node the ask is unscrolled and stores no anchor
    /// at all. Does nothing until the saved anchor has been restored.
    private func noteAnchor(_ frames: [String: CGRect], order: [String]) {
        guard restored else { return }
        let visible = Flow.visible(frames: frames, top: visibleTop, bottom: visibleBottom)
        guard let top = Flow.topVisible(visible: visible, order: order) else { return }
        let anchor: String? = top == Self.titleAnchor ? nil : top
        guard model.detailAnchor[id] != anchor else { return }
        model.detailAnchor[id] = anchor
    }

    /// Back to where you left this ask. noteAnchor is gated on `restored`, so no frame report
    /// can overwrite the anchor before this scroll is issued, in whichever order they run.
    private func restoreAnchor(_ proxy: ScrollViewProxy) {
        guard !restored else { return }
        guard let anchor = model.detailAnchor[id] else {
            restored = true
            return
        }
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            restored = true
        }
    }

    /// After a tick: bring the new current leaf in only when it starts below the visible area.
    /// A sub-step row has its own `.id(path)` and frame, so the
    /// leaf itself is the target, never its parent.
    private func scrollToCurrent(_ current: String?, proxy: ScrollViewProxy) {
        guard let current, let frame = nodeFrames[current] else { return }
        guard Flow.needsScroll(nodeTop: frame.minY, visibleBottom: visibleBottom) else { return }
        withAnimation(DS.motion(DS.Motion.step, reduce: reduceMotion)) {
            proxy.scrollTo(current, anchor: .top)
        }
    }

    /// The file rows' context: is this ask from this Mac (its `from.host` against the cached
    /// host name; a hostless ask is here only in This Mac mode), and the shell's file actions.
    private func fileContext(_ snapshot: DetailSnapshot?) -> FileRowContext {
        FileRowContext(place: FilePlace.of(askHost: snapshot?.model?.origin?.host, localHost: model.localHost,
                                           queueIsLocal: model.queueIsLocal),
                       actions: model.shell.files, copy: model.shell.copy)
    }

    private func content(_ snapshot: DetailSnapshot) -> some View {
        let closed = snapshot.closedText != nil
        return VStack(alignment: .leading, spacing: DS.Space.section) {
            if let notice = model.notice {
                Notice(kind: notice.kind, text: notice.text, actionTitle: notice.actionTitle, help: notice.help,
                       secondaryTitle: notice.secondaryActionTitle, onSecondary: { model.performNoticeSecondaryAction() },
                       onAction: { model.performNoticeAction() }, onDismiss: { model.dismissNotice() })
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            titleBlock(snapshot)
                .id(Self.titleAnchor)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: NodeFramesKey.self,
                                           value: [Self.titleAnchor: geometry.frame(in: .named(detailScrollSpace))])
                })
            stepsArea(snapshot, closed: closed)
            replySection(snapshot, closed: closed)
            repliesSection(snapshot)
            linksSection(snapshot)
            fromSection(snapshot)
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, DS.Space.bodyV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.fileRowContext, fileContext(snapshot))
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: model.notice)
    }

    private func header(_ snapshot: DetailSnapshot) -> some View {
        TimelineView(.everyMinute) { context in
            DetailHeaderBar(
                project: snapshot.row.project, urgency: snapshot.row.urgency,
                age: RelativeAge.text(created: snapshot.row.created, now: gallery.now ?? context.date),
                previous: snapshot.previous, next: snapshot.next,
                onBack: { model.back() },
                onPrevious: { if let other = Self.target(snapshot.previous) { model.open(other) } },
                onNext: { if let other = Self.target(snapshot.next) { model.open(other) } },
                onHide: { model.shell.hide() },
                onDock: { model.shell.dock($0) },
                menu: QueueContextMenu.resumeEntries(for: snapshot.row, localHost: model.localHost),
                onMenu: { command in
                    switch command {
                    case .resume: if let origin = snapshot.row.origin { model.shell.resume(origin) }
                    case .copyResume: if let resume = snapshot.row.resumeCommand { model.shell.copy(resume) }
                    default: break
                    }
                })
        }
    }

    private func titleBlock(_ snapshot: DetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            Text(line(snapshot.model?.title ?? snapshot.row.title))
                .font(DS.Font.askTitle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            if let why = snapshot.model?.why {
                Text(prose(why))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((snapshot.model?.notes ?? []).enumerated()), id: \.offset) { _, note in
                Text(prose(note))
                    .font(DS.Font.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func replySection(_ snapshot: DetailSnapshot, closed: Bool) -> some View {
        if let spec = snapshot.model?.reply {
            DetailReply(model: model, snapshot: snapshot, spec: spec, closed: closed, isFocused: $replyFocused)
        }
    }

    /// An ask that takes a reply shows its replies in the Reply section (the answer row and
    /// History); this list is for replies to an ask without one.
    @ViewBuilder private func repliesSection(_ snapshot: DetailSnapshot) -> some View {
        if !snapshot.replies.isEmpty, snapshot.model?.reply == nil {
            VStack(alignment: .leading, spacing: DS.Space.inline) {
                Text("Your replies")
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                RepliesList(snapshot.replies)
            }
        }
    }

    private var fromExpanded: Binding<Bool> {
        Binding(get: { gallery.fromExpanded ?? storedFromExpanded }, set: { storedFromExpanded = $0 })
    }

    @ViewBuilder private func linksSection(_ snapshot: DetailSnapshot) -> some View {
        if let links = snapshot.model?.links, !links.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.inline) {
                Text("Links")
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                ForEach(links.indices, id: \.self) { index in
                    linkRow(links[index])
                }
            }
        }
    }

    /// "label · host" for a web link; a file row for a local `path`; anything else is
    /// shown as text, never opened.
    @ViewBuilder private func linkRow(_ link: LinkRef) -> some View {
        if let raw = link.url, LinkDisplay.isWeb(raw), let url = URL(string: raw) {
            OpenLink(title: LinkDisplay.linkTitle(label: link.label, url: raw), url: url)
        } else if let raw = link.file, let file = FileLink(raw, home: NSHomeDirectory()) {
            FileRow(link: file, label: link.label)
        } else {
            RefusedLink(text: LinkDisplay.refusedText(label: link.label), raw: link.url ?? link.path ?? "")
        }
    }

    /// Only when the ask has a usable origin.
    @ViewBuilder private func fromSection(_ snapshot: DetailSnapshot) -> some View {
        if let origin = snapshot.model?.origin {
            FromDisclosure(origin: origin, expanded: fromExpanded, onCopy: { model.shell.copy($0) })
        }
    }

    /// Until the detail loads: a labelled spinner, then after 10 s (DetailLoadState) the
    /// failure line and Try Again. While loading, the snapshot is re-read once a second.
    @ViewBuilder private func stepsArea(_ snapshot: DetailSnapshot, closed: Bool) -> some View {
        switch snapshot.load {
        case .loaded:
            if let detail = snapshot.model, !detail.nodes.isEmpty {
                DetailSteps(model: model, snapshot: snapshot, nodes: detail.nodes, readOnly: closed)
            }
        case .loading, .timedOut:
            TimelineView(.periodic(from: Date(), by: DS.Motion.wakeRecheck)) { _ in
                loadingView(model.detail(id)?.load ?? snapshot.load)
            }
        }
    }

    @ViewBuilder private func loadingView(_ state: DetailLoadState) -> some View {
        switch state {
        case .timedOut:
            VStack(alignment: .leading, spacing: DS.Space.inline) {
                Text("Couldn't load this ask.")
                    .foregroundStyle(DS.Color.secondary)
                Button("Try Again") { model.retryDetail(id) }
                    .controlSize(DS.Control.form)
            }
        case .loading:
            ProgressView { Text("Loading steps…") }
                .controlSize(DS.Control.inline)
                .accessibilityLabel("Loading steps")
        case .loaded:
            EmptyView()
        }
    }

    private func bottomBars(_ snapshot: DetailSnapshot) -> some View {
        VStack(spacing: 0) {
            if let undo = model.undoInfo {
                UndoBar(undo: undo, sending: model.sendingCloses > 0, onUndo: { model.undo() })
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            ActionBar(mode: Self.actionMode(snapshot), answers: Self.answers(snapshot),
                      onSkip: { model.close(id, .declined) },
                      onPrimary: { primary(snapshot) },
                      onReopen: { model.reopen(id) },
                      onSendAndDone: { model.sendAndDone(id) },
                      onDiscard: { model.discardAndDone(id) })
        }
        .animation(DS.motion(DS.Motion.reveal, reduce: reduceMotion), value: model.undoInfo)
        // The bars grow past DS.Metric.actionBar (a wrapped caption, the undo bar), so the
        // visible band is measured, the same way the viewport is.
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { barHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in barHeight = height }
        })
    }

    private func primary(_ snapshot: DetailSnapshot) {
        switch snapshot.primary {
        case .done: model.close(id, .done)
        case .sendAndDone: model.warnUnsent(id)
        }
    }
}
