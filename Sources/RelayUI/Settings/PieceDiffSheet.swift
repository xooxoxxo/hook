import RelayCore
import SwiftUI

/// One line of `relay integrations diff`: its kind sets its tint.
enum DiffLineKind: Equatable {
    case header, hunk, added, removed, context

    static func of(_ line: some StringProtocol) -> DiffLineKind {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .header }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}

/// Show Difference (Fix… on a piece marked "Edited by you"): Hook's text against the file, as
/// a unified diff. A stock sheet: the file, the diff, then Close and Use Hook's….
public struct PieceDiffSheet: View {
    let diff: IntegrationDiff
    let onClose: () -> Void
    let onUseHooks: () -> Void

    public init(diff: IntegrationDiff, onClose: @escaping () -> Void, onUseHooks: @escaping () -> Void) {
        self.diff = diff
        self.onClose = onClose
        self.onUseHooks = onUseHooks
    }

    /// The diff's lines, without the empty one after its last newline.
    private var lines: [(id: Int, text: String)] {
        var all = diff.diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.count > 1, all.last == "" { all.removeLast() }
        return all.enumerated().map { (id: $0.offset, text: $0.element) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sheetSection) {
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                Text("Your file and Hook's text").font(DS.Font.heading)
                Text(diff.target)
                    .font(DS.Font.code)
                    .foregroundStyle(DS.Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.id) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(DS.Font.code)
                            .foregroundStyle(Self.foreground(DiffLineKind.of(line.text)))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.codeH)
                            .background(Self.fill(DiffLineKind.of(line.text)))
                    }
                }
                .padding(.vertical, DS.Space.codeV)
                .textSelection(.enabled)
            }
            .frame(height: DS.Metric.diffSheetBody)
            .codeBox()
            .accessibilityLabel("Difference")
            HStack(spacing: DS.Space.inline) {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Use Hook's…", action: onUseHooks)
            }
            .controlSize(DS.Control.form)
        }
        .padding(DS.Space.sheet)
        .frame(width: DS.Metric.diffSheetWidth)
    }

    private static func fill(_ kind: DiffLineKind) -> SwiftUI.Color {
        switch kind {
        case .added: DS.Color.diffAddedLine
        case .removed: DS.Color.diffRemovedLine
        case .header, .hunk, .context: .clear
        }
    }

    private static func foreground(_ kind: DiffLineKind) -> AnyShapeStyle {
        switch kind {
        case .header, .hunk: AnyShapeStyle(DS.Color.secondary)
        case .added, .removed, .context: AnyShapeStyle(DS.Color.primary)
        }
    }
}
