import AppKit
import RelayCore
import RelayUI
import RelayMacCore
import SwiftUI

/// Design/FileRow: a local document (a step's `file`, or a link's `path`), in the code
/// block's grouped fill: the type's icon, the name (or the link's label) over its folder,
/// an Open button and a ⋯ menu (Open With, Reveal in Finder, Copy Path).
/// - From another machine: "On <host>" (or "From another machine") instead of the
///   folder, and only Copy Path.
/// - Not a document type: "Hook doesn't open this kind of file", Reveal in Finder and
///   Copy Path.
/// - A network path: only Copy Path.
/// - Missing (found at a click): "File not found", and only Copy Path.
/// Rendering never touches the file: the state comes from the path, the icon from the
/// extension. A click checks the file off the main actor (`FileActions.check`) first.
public struct MacFileRow: View {
    let link: FileLink
    /// A link's label; nil for a step's file (the file name is the title).
    let label: String?
    @Environment(\.fileRowContext) private var context
    /// What the last click found, for the path it checked.
    @State private var found: (path: String, state: FileRowState)?

    public init(link: FileLink, label: String? = nil) {
        self.link = link
        self.label = label
    }

    private var state: FileRowState {
        let initial = FileRowState.of(place: context.place, link: link)
        guard initial.canOpen || initial.canReveal, let found, found.path == link.path else { return initial }
        return found.state
    }

    public var body: some View {
        let state = state
        HStack(alignment: .center, spacing: DS.Space.inline) {
            Image(nsImage: Self.icon(link))
                .resizable()
                .frame(width: DS.Metric.fileIcon, height: DS.Metric.fileIcon)
                .opacity(state.canOpen ? 1 : DS.Color.fileUnavailableOpacity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.fileLine) {
                Text(verbatim: line(label ?? link.name))
                    .font(DS.Font.prose)
                    .foregroundStyle(state.canOpen ? DS.Color.primary : DS.Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: secondary(state))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(line(link.raw))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(name: line(label ?? link.name), detail: secondary(state)))
            if state.canOpen {
                Button("Open") { run(.open, state) }
                    .controlSize(DS.Control.inline)
                    .accessibilityLabel("Open " + line(link.name))
            }
            menu(state)
        }
        .padding(.horizontal, DS.Space.codeH)
        .padding(.vertical, DS.Space.codeV)
        .background(DS.Color.codeFill, in: .rect(cornerRadius: DS.Metric.codeRadius))
        .contextMenu { menuItems(state) }
        .disabled(!context.actionsEnabled)
    }

    /// Runs `command` through `FileRowContext.perform`: a refused click beeps and says
    /// `CopyOutcome.refusedText`; a check that found no document beeps and the row shows what
    /// it found.
    private func run(_ command: FileRowCommand, _ state: FileRowState) {
        let context = context
        let link = link
        Task { @MainActor in
            let result = await context.perform(command, on: link, state: state)
            if let check = result.check { found = FileRowState.after(check).map { (link.path, $0) } }
            switch result.outcome {
            case .done: break
            case .refused:
                NSSound.beep()
                AccessibilityNotification.Announcement(CopyOutcome.refusedText).post()
            case .unavailable: NSSound.beep()
            }
        }
    }

    /// The folder (a link also names the file), or the state's note.
    private func secondary(_ state: FileRowState) -> String {
        if let note = state.note { return note }
        let folder = line(link.folder(home: context.home))
        return label == nil ? folder : folder + "/" + line(link.name)
    }

    private func menu(_ state: FileRowState) -> some View {
        Menu {
            menuItems(state)
        } label: {
            Image(systemName: DS.Symbol.more)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(DS.Control.inline)
        .accessibilityLabel("More for " + line(link.name))
        .help(state.canOpen ? "Open With, Reveal in Finder, Copy Path"
              : state.canReveal ? "Reveal in Finder, Copy Path" : "Copy Path")
    }

    @ViewBuilder private func menuItems(_ state: FileRowState) -> some View {
        if state.canOpen {
            Menu("Open With") {
                let apps = context.actions.apps(link.path)
                ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                    Button(index == 0 ? DocumentApps.name(app) + " (default)" : DocumentApps.name(app)) {
                        run(.openWith(app), state)
                    }
                }
                if !apps.isEmpty { Divider() }
                Button("Other…") { run(.openWithOther, state) }
            }
        }
        if state.canReveal {
            Button("Reveal in Finder") { run(.reveal, state) }
            Divider()
        }
        Button("Copy Path") { run(.copyPath, state) }
    }

    public static func accessibilityLabel(name: String, detail: String) -> String { name + ", " + detail }

    /// The icon for the type the extension declares: never read from the file itself.
    @MainActor static func icon(_ link: FileLink) -> NSImage {
        NSWorkspace.shared.icon(for: DocumentPolicy.type(fileName: link.path))
    }
}

extension View {
    public func macFileRows() -> some View {
        environment(\.fileRowRenderer, FileRowRenderer { link, label in AnyView(MacFileRow(link: link, label: label)) })
    }
}
