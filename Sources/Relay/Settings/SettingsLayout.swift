import SwiftUI

/// The Settings tabs' shared layout: a two-column grid with
/// right-aligned labels, and the window's padding and width.
enum SettingsLayout {
    static let padding: CGFloat = 24
    static let width: CGFloat = 560
    /// Between controls stacked inside one row (a radio pair, an error line).
    static let stackSpacing: CGFloat = 8
    /// Extra space above the first row of a logical group.
    static let groupGap: CGFloat = 8
}

/// The form grid. Its rows are `SettingsRow`s.
struct SettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
            content
        }
    }
}

/// One form row: the label, right-aligned in the first column, then its controls.
/// `newGroup` adds the group gap above it.
struct SettingsRow<Content: View>: View {
    private let label: String
    private let newGroup: Bool
    private let content: Content

    init(_ label: String, newGroup: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.newGroup = newGroup
        self.content = content()
    }

    var body: some View {
        GridRow {
            // Both cells get the gap, so the label and the control keep sharing the
            // first-text baseline.
            Text(verbatim: label)
                .gridColumnAlignment(.trailing)
                .padding(.top, newGroup ? SettingsLayout.groupGap : 0)
            content
                .padding(.top, newGroup ? SettingsLayout.groupGap : 0)
        }
    }
}

extension View {
    /// A taller rounded-border text field.
    func settingsField() -> some View {
        textFieldStyle(.roundedBorder).controlSize(.large)
    }

    /// A tab's padding and width.
    func settingsPage() -> some View {
        padding(SettingsLayout.padding)
            .frame(width: SettingsLayout.width, alignment: .leading)
    }
}
