import RelayUI
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

/// One Settings row. The help "?" (when given) sits right after the label text; the control
/// keeps the section's trailing edge. An `accessory` (an `IconButton` for a secondary action,
/// such as Show in Finder) is drawn on the control's line, after it, never under it. An error
/// shows as a red caption under the control.
public struct SettingsRow<Control: View, Accessory: View>: View {
    let label: String
    let help: String?
    let error: String?
    let control: Control
    let accessory: Accessory
    let hasAccessory: Bool
    @Environment(\.settingsSection) private var group

    public init(_ label: String, help: String? = nil, error: String? = nil,
                @ViewBuilder control: () -> Control, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.help = help
        self.error = error
        self.control = control()
        self.accessory = accessory()
        hasAccessory = true
    }

    public var body: some View {
        LabeledContent {
            // Trailing, so a caption wider than the control can't pull the control off the
            // section's trailing edge.
            VStack(alignment: .trailing, spacing: DS.Space.rowLine) {
                line.alignmentProbe(.settingsTrailing, group: group, measure: .frame)
                if let error {
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            HStack(spacing: DS.Space.inline) {
                Text(label)
                if let help {
                    HelpButton(rowLabel: label, text: help)
                }
            }
            .helpLabelStyle(.body)
            // An accessory's hit area makes the line as tall as an icon button; the label
            // takes the same height so it stays centred on the control's line.
            .frame(minHeight: hasAccessory ? DS.Metric.hit : nil)
        }
    }

    /// The control, then the accessory on the same line.
    @ViewBuilder private var line: some View {
        if hasAccessory {
            HStack(spacing: DS.Space.inline) {
                control.alignmentProbe(.settingsControl, group: rowKey, measure: .frame)
                accessory.alignmentProbe(.settingsAccessory, group: rowKey, measure: .frame)
            }
        } else {
            control
        }
    }

    /// Pairs this row's control and accessory probes.
    private var rowKey: String { group + " › " + (label.isEmpty ? "(no label)" : label) }
}

extension SettingsRow where Accessory == EmptyView {
    public init(_ label: String, help: String? = nil, error: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.help = help
        self.error = error
        self.control = control()
        self.accessory = EmptyView()
        hasAccessory = false
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
