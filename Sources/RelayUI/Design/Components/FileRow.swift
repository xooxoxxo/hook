import AppKit
import RelayCore
import SwiftUI
import UniformTypeIdentifiers

/// Where the file rows of one ask stand: is the ask from this Mac, and what the buttons do.
/// DetailView sets it for its subtree; rows never look up the host themselves.
public struct FileRowContext: Sendable {
    public var place: FilePlace
    public var actions: FileActions
    public var copy: @MainActor @Sendable (String) -> Void
    public var home: String

    public init(place: FilePlace = .here, actions: FileActions = .none,
                copy: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                home: String = NSHomeDirectory()) {
        self.place = place
        self.actions = actions
        self.copy = copy
        self.home = home
    }
}

private struct FileRowContextKey: EnvironmentKey {
    static let defaultValue = FileRowContext()
}

extension EnvironmentValues {
    public var fileRowContext: FileRowContext {
        get { self[FileRowContextKey.self] }
        set { self[FileRowContextKey.self] = newValue }
    }
}

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
public struct FileRow: View {
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
                Button("Open") { checked { context.actions.open($0) } }
                    .controlSize(DS.Control.inline)
                    .accessibilityLabel("Open " + line(link.name))
            }
            menu(state)
        }
        .padding(.horizontal, DS.Space.codeH)
        .padding(.vertical, DS.Space.codeV)
        .background(DS.Color.codeFill, in: .rect(cornerRadius: DS.Metric.codeRadius))
        .contextMenu { menuItems(state) }
    }

    /// Runs the click's check, then `action` on the checked file (its resolved URL and the
    /// bytes the check read) when it is a document; otherwise the row shows what the check
    /// found.
    private func checked(_ action: @escaping @MainActor (CheckedFile) -> Void) {
        check { result in
            if case .document(let file) = result { action(file) } else { NSSound.beep() }
        }
    }

    /// Reveal in Finder: the resolved file, a document or a refused one.
    private func revealChecked(_ action: @escaping @MainActor (URL) -> Void) {
        check { result in
            switch result {
            case .document(let file): action(file.url)
            case .refused(let url): action(url)
            case .missing, .network: NSSound.beep()
            }
        }
    }

    private func check(_ then: @escaping @MainActor (FileCheck) -> Void) {
        let path = link.path
        let actions = context.actions
        Task { @MainActor in
            let result = await actions.check(path)
            found = FileRowState.after(result).map { (path, $0) }
            then(result)
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
                        checked { context.actions.openWith($0, app) }
                    }
                }
                if !apps.isEmpty { Divider() }
                Button("Other…") { checked { context.actions.openWithOther($0) } }
            }
        }
        if state.canReveal {
            Button("Reveal in Finder") { revealChecked { context.actions.reveal($0) } }
            Divider()
        }
        // From another machine, "~" means that machine's home: the path goes as sent.
        Button("Copy Path") {
            if case .otherMac = state { context.copy(link.raw) } else { context.copy(link.path) }
        }
    }

    public static func accessibilityLabel(name: String, detail: String) -> String { name + ", " + detail }

    /// The icon for the type the extension declares: never read from the file itself.
    @MainActor static func icon(_ link: FileLink) -> NSImage {
        NSWorkspace.shared.icon(for: DocumentPolicy.type(fileName: link.path))
    }
}
