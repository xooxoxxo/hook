import RelayCore
import SwiftUI

/// A platform presentation adapter. The file context remains responsible for guarded actions.
public struct FileRowRenderer: Sendable {
    let render: @MainActor @Sendable (FileLink, String?) -> AnyView
    public init(_ render: @escaping @MainActor @Sendable (FileLink, String?) -> AnyView) { self.render = render }
}
private struct FileRowRendererKey: EnvironmentKey { static let defaultValue: FileRowRenderer? = nil }
extension EnvironmentValues {
    public var fileRowRenderer: FileRowRenderer? {
        get { self[FileRowRendererKey.self] }
        set { self[FileRowRendererKey.self] = newValue }
    }
}

/// Portable file presentation: origin and the full path, with a guarded Copy Path action.
/// Mac hosts install their native renderer to offer checked local document operations.
public struct FileRow: View {
    let link: FileLink
    let label: String?
    @Environment(\.fileRowRenderer) private var renderer
    @Environment(\.fileRowContext) private var context
    public init(link: FileLink, label: String? = nil) { self.link = link; self.label = label }
    public var body: some View {
        if let renderer {
            renderer.render(link, label)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                Text(verbatim: line(label ?? link.name)).font(DS.Font.prose)
                if case .otherMac(let host) = context.place {
                    Text(verbatim: line(host.map { "On " + $0 } ?? FileRowState.unknownMachine)).font(DS.Font.caption)
                }
                Text(verbatim: line(link.raw)).font(DS.Font.code).askTextSelection()
                Button("Copy Path") {
                    Task { @MainActor in
                        let result = await context.perform(.copyPath, on: link, state: .otherMac(nil))
                        if result.outcome == .refused { AccessibilityNotification.Announcement(CopyOutcome.refusedText).post() }
                    }
                }
                .disabled(!context.actionsEnabled)
            }
            .padding(.horizontal, DS.Space.codeH)
            .padding(.vertical, DS.Space.codeV)
            .background(DS.Color.codeFill, in: .rect(cornerRadius: DS.Metric.codeRadius))
        }
    }
    public static func accessibilityLabel(name: String, detail: String) -> String { name + ", " + detail }
}
