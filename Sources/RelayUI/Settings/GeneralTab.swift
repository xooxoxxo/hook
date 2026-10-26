import RelayCore
import SwiftUI

/// Settings → General: shortcut, presence, login and the menu-bar badge, appearance
/// and version. Every control but the login item writes config.json through the model.
public struct GeneralTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            // One row: the shortcut is the app's main entry point, and its error caption appears under it.
            Section("Shortcut") {
                SettingsRow("Show or hide Relay", help: GeneralHelp.shortcut, error: model.settings.shortcutProblem?.text) {
                    ShortcutField(
                        label: model.settings.shortcutLabel ?? "Not set",
                        onBegin: { model.perform(.beginShortcut) },
                        onRecord: { model.perform(.recordShortcut($0)) },
                        onCancel: { model.perform(.cancelShortcut) },
                        onClear: { model.perform(.clearShortcut) })
                }
            }
            .environment(\.settingsSection, "Shortcut")
            .disabled(model.settings.readOnly)
            Section("Presence") {
                SettingsRow("Presence", help: GeneralHelp.presence) {
                    Picker("Presence", selection: model.configBinding(
                        "presence", \.presence, fallback: PresenceMode.auto, encode: { $0.rawValue })) {
                        Text("Automatic").tag(PresenceMode.auto)
                        Text("Home").tag(PresenceMode.home)
                        Text("Away").tag(PresenceMode.away)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                if (model.settings.config?.presence ?? .auto) == .auto {
                    SettingsRow("Away after") {
                        Picker("Away after", selection: model.configBinding(
                            "awayAfterMinutes", \.awayAfterMinutes, fallback: PresenceLogic.defaultAwayAfterMinutes,
                            encode: { $0 })) {
                            ForEach(PresenceLogic.awayAfterChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                }
                SettingsRow("Right now") {
                    Label {
                        Text(model.settings.presenceLine).foregroundStyle(DS.Color.secondary)
                    } icon: {
                        Image(systemName: model.settings.away ? DS.Symbol.away : DS.Symbol.statusOK)
                            .imageScale(.small)
                            .foregroundStyle(model.settings.away ? DS.Color.secondary : DS.Color.done)
                    }
                }
            }
            .environment(\.settingsSection, "Presence")
            .disabled(model.settings.readOnly)
            Section("Startup and menu bar") {
                SettingsRow("Login", help: GeneralHelp.login, error: model.settings.login.error) {
                    Toggle("Start Relay when I log in", isOn: Binding(
                        get: { model.settings.login.on },
                        set: { model.perform(.setLogin($0)) }))
                        .toggleStyle(.checkbox)
                }
                if model.settings.login.needsApproval {
                    SettingsRow("", error: "Approve Relay in System Settings → Login Items.") {
                        Button("Open Login Items") { model.perform(.openLoginItems) }
                    }
                }
            }
            .environment(\.settingsSection, "Startup and menu bar")
            .disabled(model.settings.readOnly)
            Section("Appearance and version") {
                SettingsRow("Appearance") {
                    Picker("Appearance", selection: model.configBinding(
                        "appearance", \.appearance, fallback: AppearanceSetting.system, encode: { $0.rawValue })) {
                        Text("System").tag(AppearanceSetting.system)
                        Text("Light").tag(AppearanceSetting.light)
                        Text("Dark").tag(AppearanceSetting.dark)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                SettingsRow("Version") {
                    Text(model.settings.version).foregroundStyle(DS.Color.secondary).monospacedDigit()
                    Button("Show config.json") { model.perform(.showConfigInFinder) }
                }
            }
            .environment(\.settingsSection, "Appearance and version")
            .disabled(model.settings.readOnly)
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }
}

/// The General tab's "?" texts.
public enum GeneralHelp {
    public static let shortcut = "Click the field, then press the new keys. Use at least one of ⌘, ⌃ or ⌥ with a letter, a digit, Space, ` or F1–F12. Esc cancels. ⊗ turns the shortcut off."
    public static let presence = "Relay marks you away when the screen locks, the displays sleep, you're connected over Screen Sharing, or you haven't touched the Mac for this long. While you're away, Relay doesn't slide the panel in or show notifications; asks still reach anything your mailbox forwards them to. Relay also creates ~/.local/state/relay/away, so other tools can tell. For example, ssh can skip the 1Password agent."
    public static let login = "Relay adds a LaunchAgent so it starts when you log in."
}
