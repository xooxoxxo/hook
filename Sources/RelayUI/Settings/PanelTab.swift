import RelayCore
import SwiftUI

/// Settings → Panel: the edge and display the panel docks to, sliding in on Now asks,
/// and what Done or Skip opens next. Every control writes config.json through the model.
public struct PanelTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            Section("Position") {
                SettingsRow("Edge", help: PanelHelp.edge) {
                    Picker("Edge", selection: model.configBinding(
                        "sidebarEdge", \.sidebarEdge, fallback: SidebarEdge.right, encode: { $0.rawValue })) {
                        Text("Left").tag(SidebarEdge.left)
                        Text("Right").tag(SidebarEdge.right)
                    }
                    .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                }
                SettingsRow("Display", help: PanelHelp.display) {
                    Picker("Display", selection: Binding(
                        get: { model.settings.config?.sidebarDisplay },
                        set: { id in
                            if let id { model.save(set: ["sidebarDisplay": id], remove: []) }
                            else { model.save(set: [:], remove: ["sidebarDisplay"]) }
                        })) {
                        ForEach(model.settings.displays) { option in
                            Text(option.title).tag(option.id).disabled(!option.connected)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                SettingsRow("", help: nil) {
                    Button("Re-dock Now") { model.perform(.redockNow) }
                }
            }
            .environment(\.settingsSection, "Position")
            .disabled(model.settings.readOnly)
            Section("Behaviour") {
                SettingsRow("Now asks", help: PanelHelp.slideIn) {
                    Toggle("Slide the panel in", isOn: Binding(
                        get: { model.settings.config?.notify.slideIn ?? true },
                        set: { on in
                            var notify = model.settings.config?.notify ?? NotifySettings()
                            notify.slideIn = on
                            model.save(set: ["notify": notify.configObject], remove: [])
                        }))
                        .toggleStyle(.checkbox)
                }
                SettingsRow("After Done or Skip", help: nil) {
                    Picker("After Done or Skip", selection: model.configBinding(
                        "afterClose", \.afterClose, fallback: AfterClose.next, encode: { $0.rawValue })) {
                        Text("Open the next ask").tag(AfterClose.next)
                        Text("Go back to the queue").tag(AfterClose.queue)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            .environment(\.settingsSection, "Behaviour")
            .disabled(model.settings.readOnly)
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }
}

/// The Panel tab's "?" texts.
public enum PanelHelp {
    public static let edge = "You can also drag the panel by its top bar to either edge of any display. It stays there until you move it."
    public static let display = "If this display is disconnected, Relay uses the main display until it comes back."
    public static let slideIn = "The panel opens on the new ask without taking keyboard focus. Press the shortcut or click ✕ to hide it. This works even when Now notifications are off. It doesn't happen while you're away."
}
