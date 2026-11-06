import Foundation
import RelayCore

/// What a file row's buttons do. The app builds one over `DocumentOpener`; the gallery and
/// tests use `.none` or their own. A row first runs `check` on the path (off the main
/// actor), and only a `.document` result reaches `open`, `openWith` or `openWithOther`,
/// which take the checked file: its resolved URL, never the path the ask named.
public struct FileActions: Sendable {
    /// The click-time checks (`FileAccess.check`); never called while a row renders. The
    /// live one also reads the file's bytes when Open would show it in the viewer.
    public var check: @Sendable (String) async -> FileCheck
    public var open: @MainActor @Sendable (CheckedFile) -> Void
    public var openWith: @MainActor @Sendable (CheckedFile, URL) -> Void
    /// Open With › Other…: pick an app, then open the file in it.
    public var openWithOther: @MainActor @Sendable (CheckedFile) -> Void
    public var reveal: @MainActor @Sendable (URL) -> Void
    /// The apps that open files named like this (by type, never the file): the default
    /// first, then the rest by name.
    public var apps: @MainActor @Sendable (String) -> [URL]

    public init(check: @escaping @Sendable (String) async -> FileCheck,
                open: @escaping @MainActor @Sendable (CheckedFile) -> Void,
                openWith: @escaping @MainActor @Sendable (CheckedFile, URL) -> Void,
                openWithOther: @escaping @MainActor @Sendable (CheckedFile) -> Void,
                reveal: @escaping @MainActor @Sendable (URL) -> Void,
                apps: @escaping @MainActor @Sendable (String) -> [URL]) {
        self.check = check
        self.open = open
        self.openWith = openWith
        self.openWithOther = openWithOther
        self.reveal = reveal
        self.apps = apps
    }

    public static let none = FileActions(check: { _ in .missing }, open: { _ in }, openWith: { _, _ in },
                                         openWithOther: { _ in }, reveal: { _ in }, apps: { _ in [] })

}
