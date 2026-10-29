import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Every control in a section ends on one trailing edge. SettingsRow probes its
/// control as `.settingsTrailing`; the grouped Form gives every section the same width.
let settingsRules: [AlignmentRule] = [.sameTrailingPerGroup(.settingsTrailing, tolerance: 1)]

/// A Settings scene: the real toolbar-tab window chrome around `view` on `tab`.
@MainActor func settingsScene<V: View>(_ name: String, tab: SettingsTabID, rules: [AlignmentRule] = settingsRules,
                                       _ view: @escaping @MainActor () -> V) -> GalleryScene {
    GalleryScene(name: name, size: .settings(tab: tab.rawValue), standIn: false, rules: rules,
                 view: { AnyView(view()) }, appKit: nil)
}

/// One entry per Settings tab state.
@MainActor var settingsScenes: [GalleryScene] {
    [
        settingsScene("settings-general", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot()))
        },
        // Updates from a git checkout (developer mode) instead of the release download.
        settingsScene("settings-general-developer", tab: .general) {
            var snapshot = SettingsFixtures.snapshot()
            snapshot.install = InstallKind.checkout(repo: "/Users/me/src/hook").line(home: "/Users/me")
            return GeneralTab(model: FixtureSettingsModel(settings: snapshot))
        },
        // "Open documents in" set to a chosen app, named in the picker.
        settingsScene("settings-general-document-app", tab: .general) {
            var config = SettingsFixtures.mailboxConfig
            config.openDocumentsIn = "com.example.writer"
            var snapshot = SettingsFixtures.snapshot(config: config)
            snapshot.documentAppName = "Writer"
            return GeneralTab(model: FixtureSettingsModel(settings: snapshot))
        },
        settingsScene("settings-readonly", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(readOnly: true)))
        },
        settingsScene("settings-general-shortcut-unsupported", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(shortcutProblem: .unsupportedKey)))
        },
        settingsScene("settings-general-shortcut-refused", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(shortcutProblem: .refused)))
        },
        // A failed resume turns the shortcut off, so the field reads "Not set".
        settingsScene("settings-general-shortcut-resumefailed", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
                shortcutLabel: nil, shortcutProblem: .resumeFailed)))
        },
        settingsScene("settings-general-login-error", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(login: LoginState(
                on: false, error: "Couldn't change the login item. The file couldn't be saved."))))
        },
        // View-supported only: login is a LaunchAgent, so the app never reports needsApproval today.
        settingsScene("settings-general-needs-approval", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(login: LoginState(
                on: true, needsApproval: true))))
        },
        settingsScene("settings-general-away", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(away: true)))
        },
        settingsScene("settings-general-away-manual", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
                config: SettingsFixtures.manualAwayConfig, away: true, presenceLine: "Away · set by you · since 10:22")))
        },
        settingsScene("settings-panel", tab: .panel) {
            PanelTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(displays: [
                DisplayOption(id: nil, title: "Main display", connected: true),
                DisplayOption(id: "D1", title: "Studio Display", connected: true),
                DisplayOption(id: "D2", title: "Projector (not connected)", connected: false),
            ])))
        },
        settingsScene("settings-queue-local", tab: .queue) {
            QueueTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: SettingsFixtures.localConfig)))
        },
        settingsScene("settings-queue-mailbox", tab: .queue,
                      rules: settingsRules + [.sameLeading(.mailboxField, tolerance: 1)]) {
            QueueTab(model: FixtureSettingsModel(
                settings: SettingsFixtures.snapshot(),
                draft: MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/.config/relay/mailbox-token")))
        },
        settingsScene("settings-queue-mailbox-behind", tab: .queue) {
            QueueTab(model: FixtureSettingsModel(
                settings: SettingsFixtures.snapshot(config: SettingsFixtures.mailboxUpdateConfig,
                                                    mailbox: SettingsFixtures.mailboxBehind),
                draft: MailboxDraft(address: "https://mailbox.example:8790", tokenFile: "~/.config/relay/mailbox-token")))
        },
        settingsScene("settings-queue-unsaved", tab: .queue,
                      rules: settingsRules + [.sameLeading(.mailboxField, tolerance: 1)]) {
            QueueTab(model: FixtureSettingsModel(
                settings: SettingsFixtures.snapshot(problems: ["Port 47823 is in use by another app"]),
                draft: MailboxDraft(address: "https://mailbox.example:8791", tokenFile: "~/.config/relay/mailbox-token",
                                    context: "work")))
        },
        settingsScene("settings-notifications", tab: .notifications) {
            NotificationsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(away: true)))
        },
        settingsScene("settings-notifications-denied", tab: .notifications) {
            NotificationsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(permission: .denied)))
        },
        settingsScene("settings-notifications-notdetermined", tab: .notifications) {
            NotificationsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(permission: .notDetermined)))
        },
        settingsScene("settings-notifications-sent", tab: .notifications) {
            NotificationsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot()), sent: true)
        },
        settingsScene("settings-notifications-readonly", tab: .notifications) {
            NotificationsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(readOnly: true)))
        },
        settingsScene("settings-connect", tab: .connect) {
            ConnectTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: SettingsFixtures.localConfig)))
                .environment(\.panelGallery, PanelGalleryOverrides(now: GalleryFixtures.now))
        },
        settingsScene("settings-connect-norepo", tab: .connect) {
            ConnectTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
                config: RelayConfig(source: .local), repo: RepoState(cliFound: false))))
                .environment(\.panelGallery, PanelGalleryOverrides(now: GalleryFixtures.now))
        },
    ]
}
