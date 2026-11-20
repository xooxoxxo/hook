import RelayUIMac
import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Every control in a section ends on one trailing edge. SettingsRow probes its
/// control as `.settingsTrailing`; the grouped Form gives every section the same width.
/// A row's accessory (an icon button) sits on its control's line, never under it.
let settingsRules: [AlignmentRule] = [.sameTrailingPerGroup(.settingsTrailing, tolerance: 1), .settingsAccessoryInline]

/// A Settings scene: the real toolbar-tab window chrome around `view` on `tab`.
@MainActor func settingsScene<V: View>(_ name: String, tab: SettingsTabID, rules: [AlignmentRule] = settingsRules,
                                       _ view: @escaping @MainActor () -> V) -> GalleryScene {
    GalleryScene(name: name, size: .settings(tab: tab.rawValue), standIn: false, rules: rules,
                 view: { AnyView(view()) }, appKit: nil)
}

/// One entry per Settings tab state.
@MainActor var settingsScenes: [GalleryScene] {
    [
        GalleryScene(name: "settings-phone-pairing", size: .wide(width: 380, height: nil), standIn: false, view: {
            AnyView(PhonePairingView(host: "pond.example.test"))
        }),
        settingsScene("settings-queue-owner-devices", tab: .queue) {
            var config = SettingsFixtures.mailboxConfig
            config.mailboxURL = "https://pond.example.test"
            config.tokenFile = "unused"
            let status = OwnerStatus(required: false, keys: [
                OwnerKeyRow(id: "mac-key", label: "This Mac", status: "approved", created: ""),
                OwnerKeyRow(id: "phone-key", label: "iPhone", status: "approved", created: ""),
            ], self_: OwnerSelf(id: "mac-key", status: "approved"))
            return QueueTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: config),
                draft: MailboxDraft(address: "https://pond.example.test", tokenFile: "unused"), ownerKeyState: .approved,
                ownerStatus: status, canRequireOwnerKey: true))
        },
        // The Devices sheet: this Mac's key works, the older duplicate selected.
        devicesScene("settings-devices", selection: "k-old-1") {
            FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: ownerConfig), ownerKeyState: .approved,
                                 ownerStatus: SettingsFixtures.devices(), pondCapabilities: SettingsFixtures.devicesPond)
        },
        // No working key on this Mac: the revoke waits for the owner's tap on Telegram.
        devicesScene("settings-devices-telegram", selection: "k-old-1") {
            FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: ownerConfig),
                                 ownerKeyState: .refused(OwnerKeyFlow.noLongerAccepted),
                                 ownerStatus: SettingsFixtures.devices(thisMac: false),
                                 pondCapabilities: SettingsFixtures.devicesPond, setUpRefusedFull: true,
                                 revokeRequest: .waiting(keyID: "k-old-1", requestID: "r1", code: "482913", expires: nil))
        },
        // The revoke went through after a stuck setup: Set Up This Mac… is offered.
        devicesScene("settings-devices-revoked") {
            var status = SettingsFixtures.devices(thisMac: false)
            status.keys.removeAll { $0.id == "k-old-1" || $0.id == "k-mac" }
            return FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: ownerConfig),
                                        ownerKeyState: .refused(OwnerKeyFlow.enrollRefused(QueueError.rejected(status: 409, error: "too many keys", details: []))),
                                        ownerStatus: status, pondCapabilities: SettingsFixtures.devicesPond,
                                        setUpRefusedFull: true, revokeRequest: .revoked(keyID: "k-old-1"))
        },
        // An older Pond: names only, and revoke only with this Mac's key.
        devicesScene("settings-devices-older-pond") {
            FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: ownerConfig), ownerKeyState: .approved,
                                 ownerStatus: SettingsFixtures.devices(maxKeys: nil),
                                 pondCapabilities: PondCapabilities(version: .semver(SemVer(major: 1, minor: 9, patch: 0)),
                                                                    features: ["appendSteps"]))
        },
        // Setup refused with "too many keys": Choose a Device to Revoke… opens the sheet.
        settingsScene("settings-queue-owner-full", tab: .queue, rules: []) {
            var status = SettingsFixtures.devices(thisMac: false, maxKeys: 4)
            status.keys.removeAll { $0.id == "k-mac" }
            status.keys.append(OwnerKeyRow(id: "k-tab", label: "Tablet", status: "approved",
                                           created: "2026-09-20T10:00:00+00:00"))
            return QueueTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: ownerConfig),
                draft: MailboxDraft(address: "https://pond.example.test", tokenFile: "unused"),
                ownerKeyState: .refused(OwnerKeyFlow.enrollRefused(QueueError.rejected(status: 409, error: "too many keys", details: []))), ownerStatus: status,
                pondCapabilities: SettingsFixtures.devicesPond, setUpRefusedFull: true))
        },
        settingsScene("settings-general", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot()))
        },
        // Updates from a git checkout (developer mode) instead of the release download.
        settingsScene("settings-general-developer", tab: .general) {
            var snapshot = SettingsFixtures.snapshot()
            snapshot.install = InstallKind.checkout(repo: "/Users/me/src/hook").line(home: "/Users/me")
            return GeneralTab(model: FixtureSettingsModel(settings: snapshot))
        },
        // Documents: Open in Hook's viewer, the System theme, full width.
        settingsScene("settings-documents", tab: .documents) {
            DocumentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot()))
        },
        // Sepia with the owner's own heading and link colours, a narrow column, text one step up.
        settingsScene("settings-documents-themed", tab: .documents) {
            var config = SettingsFixtures.mailboxConfig
            config.viewer = ViewerTheme(preset: .sepia, colors: [.headings: "#7a2e0e", .links: "#1f5f8b"],
                                        width: .narrow, textSize: 1)
            return DocumentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: config)))
        },
        settingsScene("settings-documents-night", tab: .documents) {
            var config = SettingsFixtures.mailboxConfig
            config.viewer = ViewerTheme(preset: .night)
            return DocumentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: config)))
        },
        // "Open documents in" set to a chosen app, named in the picker.
        settingsScene("settings-documents-app", tab: .documents) {
            var config = SettingsFixtures.mailboxConfig
            config.openDocumentsIn = "com.example.writer"
            var snapshot = SettingsFixtures.snapshot(config: config)
            snapshot.documentAppName = "Writer"
            return DocumentsTab(model: FixtureSettingsModel(settings: snapshot))
        },
        // Privacy with My Pond on offer (a Pond and an approved owner key), sending there.
        settingsScene("settings-privacy", tab: .privacy) {
            var config = SettingsFixtures.mailboxConfig
            config.crashReportTarget = .pond
            return PrivacyTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(config: config)))
        },
        // No owner key yet: Send to offers GitHub only, and a saved pond reads as GitHub.
        settingsScene("settings-privacy-no-pond", tab: .privacy) {
            var config = SettingsFixtures.mailboxConfig
            config.crashReportTarget = .pond
            return PrivacyTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
                config: config, ownerKey: .notSetUp, logSize: 2_048)))
        },
        // Save Diagnostics… on the Privacy row's line: collecting (the button waits), then saved.
        settingsScene("settings-privacy-diagnostics-collecting", tab: .privacy) {
            var snapshot = SettingsFixtures.snapshot()
            snapshot.privacy.diagnostics = .collecting
            return PrivacyTab(model: FixtureSettingsModel(settings: snapshot))
        },
        settingsScene("settings-privacy-diagnostics-saved", tab: .privacy) {
            var snapshot = SettingsFixtures.snapshot()
            snapshot.privacy.diagnostics = .saved("hook-diagnostics-2026-10-16-0940.txt")
            return PrivacyTab(model: FixtureSettingsModel(settings: snapshot))
        },
        settingsScene("settings-readonly", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(readOnly: true)))
        },
        settingsScene("settings-documents-readonly", tab: .documents) {
            DocumentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(readOnly: true)))
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
        // Settings › Agents (direction B): Claude Code, all set up.
        agentsScene("settings-agents", selection: "claude-code"),
        // Codex needs the owner: "Your step" with Show Ask, no header button.
        agentsScene("settings-agents-needs", selection: "codex"),
        // OpenCode edited by the owner: a Fix… menu on each edited piece.
        agentsScene("settings-agents-edited", selection: "opencode"),
        // Gemini CLI with an update ready: the header's Update button.
        agentsScene("settings-agents-update", selection: "gemini-cli"),
        // Cursor found and not set up: Set Up, every piece "Not set up".
        agentsScene("settings-agents-notsetup", selection: "cursor"),
        // Zed has no replies hook: "Installed · no replies", "Not available in Zed".
        agentsScene("settings-agents-zed", selection: "zed"),
        // "9 more supported", expanded and scrolled into view: dimmed marks, nothing to select.
        {
            var scene = agentsScene("settings-agents-more", selection: "zed", moreExpanded: true)
            scene.scrollListsToEnd = true
            return scene
        }(),
        // Reinstall All ran with two of the owner's edits left alone.
        agentsScene("settings-agents-reinstalled", selection: "claude-code",
                    result: "Reinstalled. 2 changes you made stay as you left them."),
        settingsScene("settings-agents-norepo", tab: .agents, rules: []) {
            AgentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
                config: RelayConfig(source: .local), agents: AgentsState())))
                .environment(\.panelGallery, PanelGalleryOverrides(now: GalleryFixtures.now))
        },
        // Show Difference's sheet.
        GalleryScene(name: "settings-agents-diff", size: .wide(width: DS.Metric.diffSheetWidth, height: nil),
                     standIn: false, view: {
                         AnyView(PieceDiffSheet(diff: SettingsFixtures.agentsDiff, onClose: {}, onUseHooks: {})
                             .background(Color(nsColor: .windowBackgroundColor)))
                     }),
    ]
}

/// A Pond on https, for the owner key scenes.
@MainActor private var ownerConfig: RelayConfig {
    var config = SettingsFixtures.mailboxConfig
    config.mailboxURL = "https://pond.example.test"
    config.tokenFile = "unused"
    return config
}

/// The Devices sheet over a window background, at its own width, on the gallery's clock.
@MainActor private func devicesScene(_ name: String, selection: String? = nil,
                                     _ model: @escaping @MainActor () -> FixtureSettingsModel) -> GalleryScene {
    GalleryScene(name: name, size: .wide(width: DS.Metric.devicesSheetWidth, height: nil), standIn: false, view: {
        AnyView(DevicesSheet(model: model(), selection: selection, onDone: {})
            .environment(\.panelGallery, PanelGalleryOverrides(now: GalleryFixtures.now, locale: Locale(identifier: "en_GB"),
                                                                timeZone: TimeZone(identifier: "UTC")))
            .background(Color(nsColor: .windowBackgroundColor)))
    })
}

/// Settings › Agents on the nine-agent Mac, opened on `selection`.
@MainActor private func agentsScene(_ name: String, selection: String, moreExpanded: Bool = false,
                                    result: String? = nil) -> GalleryScene {
    // No alignment rules: the detail Form sits beside the sidebar List, so its probes aren't
    // in the window's space. The piece rows are checked by eye and by AgentsTabTests.
    settingsScene(name, tab: .agents, rules: []) {
        var agents = SettingsFixtures.agentsMac
        agents.result = result
        return AgentsTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(
            config: SettingsFixtures.localConfig, agents: agents)), selection: selection, moreExpanded: moreExpanded)
            .environment(\.panelGallery, PanelGalleryOverrides(now: GalleryFixtures.now))
    }
}

