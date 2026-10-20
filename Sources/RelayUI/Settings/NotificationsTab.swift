import RelayCore
import SwiftUI

/// Settings → Notifications (§4.8): which urgencies notify, sound, permission and a test.
public struct NotificationsTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @State private var sent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    private var notify: NotifySettings { model.settings.config?.notify ?? NotifySettings() }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            Section("Notify me for") {
                SettingsRow("Notify me for", help: NotificationsHelp.kinds) {
                    VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                        checkbox("Now asks", \.now)
                        checkbox("Today asks", \.today)
                        checkbox("Whenever asks", \.whenever)
                    }
                }
                SettingsRow("Sound") { checkbox("Play a sound", \.sound) }
            }
            .environment(\.settingsSection, "Notify me for")
            .disabled(model.settings.readOnly)
            Section("Permission") {
                SettingsRow("Permission") { PermissionControl(model: model) }
                SettingsRow("Test") {
                    HStack(spacing: DS.Space.inline) {
                        if sent { Text("Sent.").foregroundStyle(DS.Color.secondary) }
                        Button("Send a Test Notification", action: sendTest)
                    }
                }
            }
            .environment(\.settingsSection, "Permission")
            if model.settings.away {
                Section("Away") {
                    SettingsRow("Away") {
                        HStack(spacing: DS.Space.inline) {
                            Text("Paused while you're away").foregroundStyle(DS.Color.secondary)
                            Button("Presence Settings…") { model.perform(.switchTab(.general)) }
                        }
                    }
                }
                .environment(\.settingsSection, "Away")
            }
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }

    private func checkbox(_ title: String, _ key: WritableKeyPath<NotifySettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { notify[keyPath: key] },
            set: { on in
                var next = notify
                next[keyPath: key] = on
                model.save(set: ["notify": next.configObject], remove: [])
            }))
            .toggleStyle(.checkbox)
    }

    private func sendTest() {
        model.perform(.sendTestNotification)
        withAnimation(DS.motion(DS.Motion.reveal, reduce: reduceMotion)) { sent = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotificationPermission.sentFor))
            sent = false
        }
    }
}

/// The Permission control for all three states; Welcome page 2 shows the same one.
public struct PermissionControl<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        let permission = model.settings.permission
        HStack(spacing: DS.Space.inline) {
            if permission == .authorized, let text = permission.statusText {
                Label(text, systemImage: "checkmark").foregroundStyle(DS.Color.secondary)
            } else if let text = permission.statusText {
                Text(text)
            }
            if let action = permission.action, let title = permission.actionTitle {
                Button(title) { model.perform(action) }
            }
        }
    }
}

/// The Notifications tab's "?" text (§4.8).
public enum NotificationsHelp {
    public static let kinds = "Each ask says how urgent it is. Now: the session is blocked on you. Today: needed today. Whenever: no rush. Relay notifies only for the kinds you tick."
}
