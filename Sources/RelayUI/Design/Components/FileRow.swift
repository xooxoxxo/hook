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
    /// The ask's content was locked when the row rendered (a correction is unreviewed): the
    /// row's buttons and menu items are disabled.
    public var contentLocked: Bool
    /// The Store's stamp-bound check for the ask (`allowsFileAction`, bound to the revision the
    /// detail rendered), given the path as sent: asked at the moment each action acts, so a
    /// correction that lands after the render refuses it. Outside an ask (the gallery) it allows.
    public var allows: @MainActor @Sendable (String) -> Bool

    public init(place: FilePlace = .here, actions: FileActions = .none,
                copy: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                home: String = NSHomeDirectory(), contentLocked: Bool = false,
                allows: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }) {
        self.place = place
        self.actions = actions
        self.copy = copy
        self.home = home
        self.contentLocked = contentLocked
        self.allows = allows
    }

    /// Whether the row's buttons and menu items do anything, as rendered.
    public var actionsEnabled: Bool { AskContentLock.allowsActions(locked: contentLocked) }

    /// The rendered lock and the Store's check now: both must let `link` act.
    @MainActor private func permits(_ link: FileLink) -> Bool { actionsEnabled && allows(link.raw) }

    /// Runs `command` on `link`, whose row shows `state`. The Store's check runs before the
    /// file check and again right before the act, so a correction that lands between the
    /// render and the click, or during the check, refuses it (`.refused`, nothing runs).
    @MainActor public func perform(_ command: FileRowCommand, on link: FileLink, state: FileRowState) async -> FileRowResult {
        guard permits(link) else { return FileRowResult(outcome: .refused) }
        if command == .copyPath {
            // From another machine, "~" means that machine's home: the path goes as sent.
            if case .otherMac = state { copy(link.raw) } else { copy(link.path) }
            return FileRowResult(outcome: .done)
        }
        let found = await actions.check(link.path)
        guard permits(link) else { return FileRowResult(outcome: .refused) }
        switch (command, found) {
        case (.open, .document(let file)): actions.open(file)
        case (.openWith(let app), .document(let file)): actions.openWith(file, app)
        case (.openWithOther, .document(let file)): actions.openWithOther(file)
        case (.reveal, .document(let file)): actions.reveal(file.url)
        case (.reveal, .refused(let url)): actions.reveal(url)
        default: return FileRowResult(outcome: .unavailable, check: found)
        }
        return FileRowResult(outcome: .done, check: found)
    }
}

/// What a file row's click asks for.
public enum FileRowCommand: Equatable, Sendable {
    case open, openWith(URL), openWithOther, reveal, copyPath
}

/// What a file row's click did, and what its file check found (nil when it didn't check).
public struct FileRowResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The action ran.
        case done
        /// The ask is locked, or changed since the row rendered: nothing ran.
        case refused
        /// The check found no document (or nothing to reveal): nothing ran.
        case unavailable
    }

    public var outcome: Outcome
    public var check: FileCheck?

    public init(outcome: Outcome, check: FileCheck? = nil) {
        self.outcome = outcome
        self.check = check
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
