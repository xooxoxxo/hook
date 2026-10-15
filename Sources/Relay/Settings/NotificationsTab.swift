import AppKit
import Combine
import RelayCore
import SwiftUI

/// Settings → Notifications: which urgencies notify, sound, and the
/// slide-in for "now" asks. A status line and a System Settings button show when
/// macOS has Relay's notifications turned off.
struct NotificationsTab: View {
    static let deniedText = "Notifications for Relay are turned off in System Settings."

    @ObservedObject private var model: AppModel
    private let notifier: Notifier
    @State private var denied = false

    private enum Key {
        case now, today, whenever, sound, slideIn
    }

    init(model: AppModel, notifier: Notifier) {
        _model = ObservedObject(wrappedValue: model)
        self.notifier = notifier
    }

    var body: some View {
        SettingsForm {
            SettingsRow("Notify for:") {
                VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
                    checkbox("Now", .now)
                    checkbox("Today", .today)
                    checkbox("Whenever", .whenever)
                }
            }
            SettingsRow("Sound:") {
                checkbox("Play sound", .sound)
            }
            SettingsRow("Sidebar:") {
                HStack(spacing: 6) {
                    checkbox("Slide the sidebar in for \"now\" asks", .slideIn)
                    HelpButton("The sidebar opens on the new ask without taking keyboard focus, and stays until you hide it.")
                }
            }
            if denied {
                SettingsRow("Permission:") {
                    VStack(alignment: .leading, spacing: SettingsLayout.stackSpacing) {
                        Text(Self.deniedText)
                        Button("Open System Settings", action: openSystemSettings)
                    }
                }
            }
        }
        .settingsPage()
        .task {
            await refreshPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { @MainActor in await refreshPermission() }
        }
    }

    private func checkbox(_ title: String, _ key: Key) -> some View {
        Toggle(title, isOn: Binding(
            get: { Self.value(model.config?.notify ?? NotifySettings(), key) },
            set: { on in
                let next = Self.setting(model.config?.notify ?? NotifySettings(), key, on)
                model.save(set: ["notify": Self.object(next)])
            }))
            .toggleStyle(.checkbox)
            .disabled(model.config == nil)
    }

    private func refreshPermission() async {
        denied = await notifier.authorizationDenied()
    }

    private func openSystemSettings() {
        var text = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier { text += "?id=\(id)" }
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }

    private static func value(_ settings: NotifySettings, _ key: Key) -> Bool {
        switch key {
        case .now: settings.now
        case .today: settings.today
        case .whenever: settings.whenever
        case .sound: settings.sound
        case .slideIn: settings.slideIn
        }
    }

    private static func setting(_ settings: NotifySettings, _ key: Key, _ on: Bool) -> NotifySettings {
        var next = settings
        switch key {
        case .now: next.now = on
        case .today: next.today = on
        case .whenever: next.whenever = on
        case .sound: next.sound = on
        case .slideIn: next.slideIn = on
        }
        return next
    }

    /// The `notify` object as config.json holds it.
    private static func object(_ settings: NotifySettings) -> [String: Any] {
        [
            "now": settings.now,
            "today": settings.today,
            "whenever": settings.whenever,
            "sound": settings.sound,
            "slideIn": settings.slideIn,
        ]
    }
}
