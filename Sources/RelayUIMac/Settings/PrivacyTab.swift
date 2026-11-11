import RelayUI
import RelayCore
import SwiftUI

/// Settings → Privacy: crash reports and where they go, the activity log, and Save
/// Diagnostics…. Every control writes config.json through the model.
public struct PrivacyTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            PrivacySection(model: model)
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }
}

/// Settings › Privacy: what happens after a crash, where a report goes, the log and diagnostics.
struct PrivacySection<Model: SettingsViewModel>: View {
    @ObservedObject var model: Model

    private var privacy: PrivacyLine { model.settings.privacy }

    var body: some View {
        Section("Privacy") {
            SettingsRow("Crash reports", help: PrivacyHelp.crashReports) {
                Picker("Crash reports", selection: model.configBinding(
                    "crashReports", \.crashReports, fallback: CrashReportsSetting.ask, encode: { $0.rawValue })) {
                    Text("Ask Each Time").tag(CrashReportsSetting.ask)
                    Text("Send Automatically").tag(CrashReportsSetting.auto)
                    Divider()
                    Text("Off").tag(CrashReportsSetting.off)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            SettingsRow("Send to", help: PrivacyHelp.sendTo) {
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
            SettingsRow("Activity log", help: PrivacyHelp.activityLog) {
                Text(privacy.sizeText).foregroundStyle(DS.Color.secondary).monospacedDigit()
            } accessory: {
                IconButton(DS.Symbol.reveal, label: "Show in Finder",
                           help: "Show the activity log in Finder") { model.perform(.showLogInFinder) }
            }
            SettingsRow("Diagnostics", help: PrivacyHelp.diagnostics) {
                Text(privacy.diagnostics.text).foregroundStyle(DS.Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } accessory: {
                IconButton(DS.Symbol.saveDiagnostics, label: PrivacyHelp.saveDiagnosticsLabel,
                           help: PrivacyHelp.saveDiagnosticsHelp) { model.perform(.saveDiagnostics) }
                    .disabled(privacy.diagnostics.collecting)
            }
        }
        .environment(\.settingsSection, "Privacy")
        .disabled(model.settings.readOnly)
    }
}

/// The Privacy tab's "?" texts.
public enum PrivacyHelp {
    public static let crashReports = "After Hook quits unexpectedly, it offers to send a redacted summary at the next launch: the Hook and macOS versions, the CPU type, the exception and Hook's own frames, and the last 40 lines of the activity log. Ask Each Time shows you exactly what goes out first. Send Automatically sends to your own Pond without asking; GitHub always waits for you to submit the issue yourself. Off sends nothing and shows nothing."
    public static let sendTo = "GitHub opens a prefilled issue in your browser for you to review and submit; before that, Hook only searches for an existing issue by the crash's signature, a short hash. My Pond files the report as a Hook bug on your Pond, without a Telegram message. It's offered once this Mac's owner key is approved."
    public static let activityLog = "Hook keeps a small activity log in ~/Library/Logs/Hook: launches and quits with their versions, the screens you open, actions by name (Done, Skip, Reply), the queue source and the Pond's version, and errors with a redacted message (for a failed Pond request, its HTTP status and route, such as asks/{id}/reply). It never records ask ids, titles, steps, replies, notes, file paths inside asks, tokens, the owner key or the Pond's address. It rolls over at 512 KB and stays under 1 MB. It stays on this Mac unless you send a crash report."
    public static let diagnostics = "Save Diagnostics… writes one text file to attach to an issue when Hook closes "
        + "and you can't tell why: the Hook and macOS versions, the copies of Hook on this Mac, the LaunchAgent's state, "
        + "how the last runs ended, the end of the activity and update logs, the names of Hook's crash files, and the "
        + "last 2 hours of system log lines about Hook. Your home folder shows as ~, your user name as <user>, and this "
        + "Mac's name, hosts and addresses as <host>. Nothing is sent; you choose where the file goes."
    public static let saveDiagnosticsLabel = "Save Diagnostics…"
    public static let saveDiagnosticsHelp = "Save a redacted diagnostics file to attach to an issue"
}
