import RelayCore
import SwiftUI

/// Settings → General: shortcut, presence, login and the menu-bar badge, the terminal
/// for Resume Session, appearance and version, and how updates install. Every control but the login item writes config.json through the model.
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
                SettingsRow("Show or hide Hook", help: GeneralHelp.shortcut, error: model.settings.shortcutProblem?.text) {
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
                SettingsRow("Login", help: GeneralHelp.login, error: loginError) {
                    Toggle("Start Hook when I log in", isOn: Binding(
                        get: { model.settings.login.on },
                        set: { model.perform(.setLogin($0)) }))
                        .toggleStyle(.checkbox)
                } accessory: {
                    if model.settings.login.needsApproval {
                        IconButton(DS.Symbol.openApp, label: "Open Login Items",
                                   help: "Open Login Items in System Settings") { model.perform(.openLoginItems) }
                    }
                }
            }
            .environment(\.settingsSection, "Startup and menu bar")
            .disabled(model.settings.readOnly)
            Section("Documents") {
                SettingsRow("Open documents in", help: GeneralHelp.documents) {
                    Picker("Open documents in", selection: documentBinding) {
                        ForEach(documentOptions) { option in
                            if option.id == DocumentChoice.otherID { Divider() }
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            .environment(\.settingsSection, "Documents")
            .disabled(model.settings.readOnly)
            Section("Sessions") {
                SettingsRow("Terminal", help: GeneralHelp.terminal) {
                    Picker("Terminal", selection: model.configBinding(
                        "terminal", \.terminal, fallback: RelayConfig.automaticTerminal, encode: { $0 })) {
                        ForEach(terminalOptions) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            .environment(\.settingsSection, "Sessions")
            .disabled(model.settings.readOnly)
            PrivacySection(model: model)
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
                } accessory: {
                    IconButton(DS.Symbol.reveal, label: "Show config.json",
                               help: "Show config.json in Finder") { model.perform(.showConfigInFinder) }
                }
            }
            .environment(\.settingsSection, "Appearance and version")
            .disabled(model.settings.readOnly)
            if let install = model.settings.install {
                Section("Updates") {
                    SettingsRow("Installed as", help: install.detail) {
                        Text(install.mode).foregroundStyle(DS.Color.secondary)
                    } accessory: {
                        IconButton(DS.Symbol.update, label: "Check for Updates…") { model.perform(.checkForUpdates) }
                    }
                }
                .environment(\.settingsSection, "Updates")
            }
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }

    /// The login item's own error, else the approval it waits for.
    private var loginError: String? {
        model.settings.login.error
            ?? (model.settings.login.needsApproval ? "Approve Hook in System Settings → Login Items." : nil)
    }

    private var documentOptions: [DocumentChoice] {
        DocumentChoice.options(current: model.settings.config?.openDocumentsIn, appName: model.settings.documentAppName)
    }

    /// Saves the picked target; Other App… opens the app chooser instead (it saves on a pick).
    private var documentBinding: Binding<String> {
        Binding(
            get: { DocumentTarget(config: model.settings.config?.openDocumentsIn).configValue },
            set: { value in
                if value == DocumentChoice.otherID {
                    model.perform(.chooseDocumentApp)
                } else {
                    model.save(set: ["openDocumentsIn": value], remove: [])
                }
            })
    }

    /// The snapshot's list, or Automatic alone before the app has looked.
    private var terminalOptions: [TerminalChoice] {
        let options = model.settings.terminals
        return options.isEmpty
            ? TerminalChoice.options(installed: [], current: model.settings.config?.terminal ?? RelayConfig.automaticTerminal)
            : options
    }
}

/// Settings › General › Privacy: what happens after a crash, where a report goes, and the log.
struct PrivacySection<Model: SettingsViewModel>: View {
    @ObservedObject var model: Model

    private var privacy: PrivacyLine { model.settings.privacy }

    var body: some View {
        Section("Privacy") {
            SettingsRow("Crash reports", help: GeneralHelp.crashReports) {
                Picker("Crash reports", selection: model.configBinding(
                    "crashReports", \.crashReports, fallback: CrashReportsSetting.ask, encode: { $0.rawValue })) {
                    Text("Ask Each Time").tag(CrashReportsSetting.ask)
                    Text("Send Automatically").tag(CrashReportsSetting.auto)
                    Divider()
                    Text("Off").tag(CrashReportsSetting.off)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            SettingsRow("Send to", help: GeneralHelp.sendTo) {
                Picker("Send to", selection: Binding(
                    get: { privacy.target },
                    set: { model.save(set: ["crashReportTarget": $0.rawValue], remove: []) })) {
                    Text("GitHub").tag(CrashTarget.github)
                    if privacy.pondOffered {
                        Text("My Pond").tag(CrashTarget.pond)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .disabled(privacy.reports == .off)
            }
            SettingsRow("Activity log", help: GeneralHelp.activityLog) {
                Text(privacy.sizeText).foregroundStyle(DS.Color.secondary).monospacedDigit()
            } accessory: {
                IconButton(DS.Symbol.reveal, label: "Show in Finder",
                           help: "Show the activity log in Finder") { model.perform(.showLogInFinder) }
            }
        }
        .environment(\.settingsSection, "Privacy")
        .disabled(model.settings.readOnly)
    }
}

/// The General tab's "?" texts.
public enum GeneralHelp {
    public static let crashReports = "After Hook quits unexpectedly, it offers to send a redacted summary at the next launch: the Hook and macOS versions, the CPU type, the exception and Hook's own frames, and the last 40 lines of the activity log. Ask Each Time shows you exactly what goes out first. Send Automatically sends to your own Pond without asking; GitHub always waits for you to submit the issue yourself. Off sends nothing and shows nothing."
    public static let sendTo = "GitHub opens a prefilled issue in your browser for you to review and submit; before that, Hook only searches for an existing issue by the crash's signature, a short hash. My Pond files the report as a Hook bug on your Pond, without a Telegram message. It's offered once this Mac's owner key is approved."
    public static let activityLog = "Hook keeps a small activity log in ~/Library/Logs/Hook: launches and quits with their versions, the screens you open, actions by name (Done, Skip, Reply), the queue source and the Pond's version, and errors with a redacted message. It never records ask ids, titles, steps, replies, notes, file paths inside asks, tokens, the owner key or the Pond's address. It rolls over at 512 KB and stays under 1 MB. It stays on this Mac unless you send a crash report."
    public static let shortcut = "Click the field, then press the new keys. Use at least one of ⌘, ⌃ or ⌥ with a letter, a digit, Space, ` or F1–F12. Esc cancels. ⊗ turns the shortcut off."
    public static let presence = "Hook marks you away when the screen locks, the displays sleep, you're connected over Screen Sharing, or you haven't touched the Mac for this long. While you're away, Hook doesn't slide the panel in or show notifications; asks still reach anything your Pond forwards them to. Hook also creates ~/.local/state/relay/away, so other tools can tell. For example, ssh can skip the 1Password agent."
    public static let login = "Hook adds a LaunchAgent so it starts when you log in."
    public static let documents = "What Open does on a document an ask links to. Hook's viewer shows Markdown (.md, .markdown) rendered and text (.txt) as it is, in a small window, without going online; other files open in their default app. The file's default app and a chosen app open every file. Each file row's ⋯ menu also has Open With, Reveal in Finder and Copy Path. Hook reads a file only when you press Open."
    public static let terminal = "Where Resume Session opens. Right-click an ask, or use the ⋯ menu in an ask, and choose Resume Session: Hook opens a new window in this terminal, goes to the session's folder and runs claude --resume with its session. It works only for sessions on this Mac. Automatic picks the first installed of Ghostty, iTerm2, WezTerm, kitty, Warp and Alacritty, else Terminal. Ghostty may ask once for permission to let Hook control it."
}
