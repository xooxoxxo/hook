import SwiftUI

private struct SettingsSectionKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The Settings section a row sits in; groups its `settingsTrailing` probe.
    /// A Settings section sets `.environment(\.settingsSection, "<section header>")`.
    public var settingsSection: String {
        get { self[SettingsSectionKey.self] }
        set { self[SettingsSectionKey.self] = newValue }
    }
}

/// One Settings row. Every row ends in a hit-wide help slot (HelpButton or empty), so all
/// controls in a section share one trailing edge (design §4.8). An error shows as a red
/// caption under the control.
public struct SettingsRow<Control: View>: View {
    let label: String
    let help: String?
    let error: String?
    let control: Control
    @Environment(\.settingsSection) private var group

    public init(_ label: String, help: String? = nil, error: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.help = help
        self.error = error
        self.control = control()
    }

    public var body: some View {
        LabeledContent(label) {
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                HStack(spacing: DS.Space.inline) {
                    control
                    helpSlot
                }
                .alignmentProbe(.settingsTrailing, group: group)
                if let error {
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var helpSlot: some View {
        if let help {
            HelpButton(rowLabel: label, text: help).frame(width: DS.Metric.hit)
        } else {
            Color.clear.frame(width: DS.Metric.hit).accessibilityHidden(true)
        }
    }
}

public extension View {
    /// A label-less rounded text field of a fixed width, for Settings rows.
    func settingsField(width: CGFloat) -> some View {
        labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .frame(width: width)
    }
}
