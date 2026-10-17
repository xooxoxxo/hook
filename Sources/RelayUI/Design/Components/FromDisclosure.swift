import RelayCore
import SwiftUI

/// Design/FromDisclosure (design §3.2, §4.4): where the ask came from. Collapsed it names the
/// session (or folder, or host); expanded it lists Folder, Host and Session and, when the origin
/// allows one, the resume command as a CodeBlock.
public struct FromDisclosure: View {
    let origin: AskOrigin
    let expanded: Binding<Bool>
    let onCopy: (String) -> Void

    public init(origin: AskOrigin, expanded: Binding<Bool>, onCopy: @escaping (String) -> Void) {
        self.origin = origin
        self.expanded = expanded
        self.onCopy = onCopy
    }

    public var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.inline, verticalSpacing: DS.Space.stepPart) {
                ForEach(Self.rows(origin), id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(DS.Color.secondary)
                        Text(verbatim: line(row.value))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let command = origin.resumeCommand {
                    GridRow {
                        Text("Resume").foregroundStyle(DS.Color.secondary)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    CodeBlock(code: command, copyLabel: "Copy the resume command", onCopy: onCopy)
                        .gridCellColumns(2)
                }
            }
            .font(DS.Font.prose)
            .padding(.top, DS.Space.stepPart)
        } label: {
            Text(Self.title(origin))
                .foregroundStyle(DS.Color.secondary)
        }
        .disclosureGroupStyle(.trailing)
    }

    /// "From session <first 8>", else "From <folder>", else "From <host>", through `line()`.
    public static func title(_ origin: AskOrigin) -> String {
        if let short = origin.shortSession { return "From session " + line(short) }
        return "From " + line(origin.folder ?? origin.host ?? "")
    }

    /// Folder, Host, Session rows that are present, raw (the view runs line() on each value).
    public static func rows(_ origin: AskOrigin) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let cwd = origin.cwd { rows.append(("Folder", cwd)) }
        if let host = origin.host { rows.append(("Host", host)) }
        if let session = origin.session { rows.append(("Session", session)) }
        return rows
    }
}
