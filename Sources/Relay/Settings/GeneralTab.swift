import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Settings → General: shortcut, launch at login, menu-bar badge count,
/// presence, sidebar edge and appearance. Every control but the login item writes config.json
/// through AppModel.save; AppDelegate applies the result.
struct GeneralTab: View {
    static let shortcutFailed = "Couldn't register this shortcut"
    static let presenceHelp = "Relay marks you away when the screen locks, the displays sleep, you're connected over Screen Sharing, or you haven't touched the Mac for this long. While you're away, Relay doesn't slide the panel in or show notifications; asks still reach anything your mailbox forwards them to. Relay also creates ~/.local/state/relay/away, so other tools can tell. For example, ssh can skip the 1Password agent."

    @ObservedObject private var model: AppModel
    @ObservedObject private var hotKeys: HotKeyManager
    @State private var launchAtLogin = LaunchAgent.isInstalled
    @State private var loginError: String?

    init(model: AppModel, hotKeys: HotKeyManager) {
        _model = ObservedObject(wrappedValue: model)
        _hotKeys = ObservedObject(wrappedValue: hotKeys)
    }

    var body: some View {
        SettingsForm {
            SettingsRow("Show or hide sidebar:") {
                VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            label: hotKeys.label,
                            onBegin: beginRecording,
                            onRecord: record,
                            onCancel: { hotKeys.resume() })
                            .fixedSize()
                            .disabled(model.config == nil)
                        Button(action: turnShortcutOff) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Turn the shortcut off")
                        .disabled(model.config == nil || hotKeys.label == HotKeyManager.offLabel)
                        HelpButton("Click the field, then press the new keys. Use at least one of ⌘, ⌃ or ⌥. Esc cancels. ⊗ turns the shortcut off.")
                    }
                    if let status = model.hotkeyStatus {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsRow("Login:", newGroup: true) {
                VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
                    HStack(spacing: 6) {
                        Toggle("Start Relay when I log in", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }))
                            .toggleStyle(.checkbox)
                        HelpButton("Adds or removes ~/Library/LaunchAgents/\(LaunchAgent.label).plist, the same file scripts/install.sh writes. Relay keeps running either way.")
                    }
                    if let loginError {
                        Text(loginError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsRow("Menu bar:", newGroup: true) {
                HStack(spacing: 6) {
                    Toggle("Show the count on the badge", isOn: Binding(
                        get: { model.config?.showCount ?? true },
                        set: { model.save(set: ["showCount": $0]) }))
                        .toggleStyle(.checkbox)
                        .disabled(model.config == nil)
                    HelpButton("The red badge shows how many asks are waiting, up to 9. With more, or with this off, it's a plain dot.")
                }
            }

            SettingsRow("Presence:", newGroup: true) {
                HStack(spacing: 6) {
                    Picker("Presence:", selection: Binding(
                        get: { model.config?.presence ?? .auto },
                        set: { model.save(set: ["presence": $0.rawValue]) })) {
                        Text("Automatic").tag(PresenceMode.auto)
                        Text("Always home").tag(PresenceMode.home)
                        Text("Away").tag(PresenceMode.away)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.config == nil)
                    HelpButton(Self.presenceHelp)
                }
            }

            if (model.config?.presence ?? .auto) == .auto {
                SettingsRow("Away after:") {
                    Picker("Away after:", selection: Binding(
                        get: { model.config?.awayAfterMinutes ?? PresenceLogic.defaultAwayAfterMinutes },
                        set: { model.save(set: ["awayAfterMinutes": $0]) })) {
                        ForEach(PresenceLogic.awayAfterChoices, id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.config == nil)
                }
            }

            SettingsRow("Sidebar edge:", newGroup: true) {
                Picker("Sidebar edge:", selection: Binding(
                    get: { model.config?.sidebarEdge ?? .right },
                    set: { model.save(set: ["sidebarEdge": $0.rawValue]) })) {
                    Text("Right").tag(SidebarEdge.right)
                    Text("Left").tag(SidebarEdge.left)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(model.config == nil)
            }

            SettingsRow("Appearance:") {
                Picker("Appearance:", selection: Binding(
                    get: { model.config?.appearance ?? .system },
                    set: { model.save(set: ["appearance": $0.rawValue]) })) {
                    Text("System").tag(AppearanceSetting.system)
                    Text("Light").tag(AppearanceSetting.light)
                    Text("Dark").tag(AppearanceSetting.dark)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(model.config == nil)
            }
        }
        .settingsPage()
        .onAppear { launchAtLogin = LaunchAgent.isInstalled }
    }

    private func beginRecording() {
        model.hotkeyStatus = nil
        hotKeys.suspend()
    }

    /// Register the new combination first; save only when that worked.
    private func record(_ spec: HotkeySpec?) {
        guard let spec, hotKeys.apply(spec.canonical) else {
            hotKeys.resume()
            model.hotkeyStatus = Self.shortcutFailed
            return
        }
        model.hotkeyStatus = nil
        model.save(set: ["hotkey": spec.canonical])
    }

    private func turnShortcutOff() {
        hotKeys.apply("")
        model.hotkeyStatus = nil
        model.save(set: ["hotkey": ""])
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try LaunchAgent.install(appPath: Bundle.main.bundlePath)
            } else {
                try LaunchAgent.remove()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAgent.isInstalled
    }
}
