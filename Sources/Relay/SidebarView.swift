import AppKit
import SwiftUI
import RelayCore
import RelayUI

/// Sidebar order: NOW, TODAY, WHENEVER, each newest first as the
/// source lists them. Unknown urgencies count as TODAY.
enum SidebarOrder {
    struct Section: Identifiable {
        let id: String          // the section title
        let items: [WireItem]
    }

    static let titles = ["NOW", "TODAY", "WHENEVER"]

    static func bucket(_ urgency: String) -> Int {
        switch urgency {
        case "now": return 0
        case "whenever": return 2
        default: return 1
        }
    }

    /// Non-empty sections only.
    static func sections(_ items: [WireItem]) -> [Section] {
        titles.indices.compactMap { index in
            let members = items.filter { bucket($0.urgency) == index }
            return members.isEmpty ? nil : Section(id: titles[index], items: members)
        }
    }

    static func flat(_ items: [WireItem]) -> [WireItem] {
        sections(items).flatMap(\.items)
    }

    /// The ask after `id` in sidebar order; nil when `id` is last or not listed.
    static func next(after id: String, in items: [WireItem]) -> String? {
        let ids = flat(items).map(\.id)
        guard let index = ids.firstIndex(of: id), index + 1 < ids.count else { return nil }
        return ids[index + 1]
    }
}

/// The footer's status line.
enum SidebarFooter {
    static func status(sourceKey: String, reachable: Bool, problem: String?) -> (text: String, ok: Bool) {
        if sourceKey == "local" {
            return reachable ? ("This Mac · ready", true) : (problem ?? "This Mac · starting", false)
        }
        if sourceKey.hasPrefix("mailbox") {
            if reachable { return ("Mailbox · ready", true) }
            return (problem.map { "Mailbox · offline: " + $0 } ?? "Mailbox · connecting", false)
        }
        return (problem ?? "No queue set up · open Settings", false)
    }
}

/// The queue list: header, banner, sections of cards, footer.
struct SidebarView: View {
    @ObservedObject private var store: Store
    @ObservedObject private var model: AppModel
    private let onSettings: () -> Void
    @State private var highlighted: String?
    @FocusState private var listFocused: Bool
    @AppStorage("relay.closedToday.expanded") private var closedExpanded = false

    init(store: Store, model: AppModel, onSettings: @escaping () -> Void) {
        _store = ObservedObject(wrappedValue: store)
        _model = ObservedObject(wrappedValue: model)
        self.onSettings = onSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = store.banner {
                bannerView(banner)
            }
            if store.items.isEmpty && store.recentlyClosed.isEmpty {
                emptyState
            } else {
                list
            }
            if let latest = store.pending.latest {
                UndoBar(close: latest) { store.undoLatest() }
            }
            Divider()
            footer
        }
    }

    // MARK: Header and banner

    private var header: some View {
        HStack(spacing: 6) {
            Text("Relay").font(.system(size: 15, weight: .semibold))
            Text(verbatim: "· \(store.items.count) waiting")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if store.refreshing {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        // Drag the header to move the panel to another edge or display.
        .background(PanelDragHandle())
    }

    /// Corrupt queue, save failed, config error, already running: dismissible.
    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(verbatim: line(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                store.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: List

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Nothing waiting").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        TimelineView(.everyMinute) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(SidebarOrder.sections(store.items)) { section in
                            Text(verbatim: section.id)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.top, 8)
                            ForEach(section.items) { item in
                                Button {
                                    store.select(item.id)
                                } label: {
                                    SidebarCard(item: item, now: context.date, highlighted: item.id == highlighted)
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        if store.items.isEmpty {
                            Text("Nothing waiting")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }
                        if !store.recentlyClosed.isEmpty {
                            closedGroup(now: context.date)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = highlighted, store.items.contains(where: { $0.id == id }) else { return .ignored }
            store.select(id)
            return .handled
        }
        .onAppear { listFocused = true }
    }

    /// "Closed today (N)", collapsed by default, after the open sections.
    @ViewBuilder private func closedGroup(now: Date) -> some View {
        Button {
            closedExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(closedExpanded ? 90 : 0))
                Text(verbatim: "Closed today (\(store.recentlyClosed.count))")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .help(closedExpanded ? "Hide asks closed in the last 24 hours" : "Show asks closed in the last 24 hours")
        if closedExpanded {
            ForEach(store.recentlyClosed) { item in
                ClosedRow(item: item, closedBy: store.closedBy(item), now: now) {
                    Task { await store.reopen(item.id) }
                }
            }
        }
    }

    private func move(_ delta: Int) {
        let ids = SidebarOrder.flat(store.items).map(\.id)
        guard !ids.isEmpty else { return }
        if let current = highlighted, let index = ids.firstIndex(of: current) {
            highlighted = ids[min(max(index + delta, 0), ids.count - 1)]
        } else {
            highlighted = delta > 0 ? ids.first : ids.last
        }
    }

    // MARK: Footer

    private var footer: some View {
        let status = SidebarFooter.status(sourceKey: store.sourceKey, reachable: store.reachable, problem: store.problem)
        return VStack(alignment: .leading, spacing: 4) {
            if let note = model.configNote {
                Text(verbatim: line(note))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            if let note = model.listenerNote {
                Text(verbatim: line(note))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.ok ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(verbatim: line(status.text))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let hint = shortcutHint {
                    Text(verbatim: hint)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        .help("Shows or hides Relay from any app")
                }
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// The registered global shortcut, e.g. "⌃⌥⌘R"; nil when off or not registered.
    private var shortcutHint: String? {
        model.shortcutLabel
    }
}

/// One ask in the list: monogram, project, age, title (2 lines), subline.
struct SidebarCard: View {
    let item: WireItem
    let now: Date
    let highlighted: Bool

    var body: some View {
        let project = item.projectId ?? ""
        let sub = SubLine.text(for: item)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                MonogramView(project: project, size: 18)
                Text(verbatim: project.isEmpty ? "—" : line(project)).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: RelativeAge.text(created: item.created, now: now)).monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            Text(verbatim: line(item.title))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !sub.isEmpty {
                Text(verbatim: sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: highlighted ? 2 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

/// The latest held-back Done or Skip, with Undo (⌘Z while the list is showing).
/// The sidebar has no text fields, so ⌘Z here never takes undo from typing; the
/// detail view, which has the reply editor, doesn't show this bar.
struct UndoBar: View {
    let close: PendingClose
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: Self.label(close))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Undo", action: undo)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }

    static func label(_ close: PendingClose) -> String {
        (close.verdict == .done ? "Done: " : "Skipped: ") + line(close.title)
    }
}

/// One ask in "Closed today": dimmed and compact, with Reopen.
struct ClosedRow: View {
    let item: WireItem
    let closedBy: String?
    let now: Date
    let reopen: () -> Void

    var body: some View {
        let project = item.projectId ?? ""
        HStack(spacing: 8) {
            MonogramView(project: project, size: 16)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: line(item.title))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: ClosedLine.text(status: item.status, closedBy: closedBy,
                                               completedAt: item.completedAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Reopen", action: reopen)
                .controlSize(.small)
                .help("Put it back in the queue")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
