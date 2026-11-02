import Foundation
import RelayCore
import SwiftUI

/// Settings › Queue › Owner Key: this Mac's key for the connected Pond. Set Up This Mac…
/// makes the key and shows the code the Telegram request repeats; the other Macs; and the
/// requirement, offered only once two Macs are approved, this one among them.
struct OwnerKeySection<Model: SettingsViewModel>: View {
    @ObservedObject var model: Model
    @State private var confirmRequire = false

    var body: some View {
        Section {
            SettingsRow("This Mac", help: OwnerKeyText.help) { thisMac }
            if case .waiting(_, let code) = model.ownerKeyState {
                codeCard(code)
                steps(code)
                LabeledContent {
                    Button("Cancel") { model.cancelOwnerKeySetup() }
                } label: {
                    HStack(spacing: DS.Space.inline) {
                        ProgressView().controlSize(DS.Control.inline).accessibilityHidden(true)
                        Text(OwnerKeyText.waiting).foregroundStyle(DS.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !others.isEmpty {
                SettingsRow("Other Macs") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(others, id: \.id) { key in
                            Text(verbatim: OwnerKeyText.row(key)).foregroundStyle(DS.Color.secondary)
                        }
                    }
                }
            }
            requireRow
        } header: {
            Text("Owner Key")
        }
        .environment(\.settingsSection, "Owner Key")
        .alert(OwnerKeyText.confirmTitle, isPresented: $confirmRequire) {
            Button("Turn On") { model.requireOwnerKey(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(OwnerKeyText.confirmMessage)
        }
    }

    /// Every key the Pond lists but this Mac's.
    private var others: [OwnerKeyRow] {
        let mine = model.ownerStatus?.self_?.id
        return (model.ownerStatus?.keys ?? []).filter { $0.id != mine }
    }

    @ViewBuilder private var thisMac: some View {
        switch model.ownerKeyState {
        case .notSetUp:
            HStack(spacing: DS.Space.inline) {
                Text("Not set up").foregroundStyle(DS.Color.secondary)
                Button(OwnerKeyText.setUp) { model.setUpOwnerKey() }
            }
        case .waiting:
            Label("Waiting for Telegram", systemImage: DS.Symbol.ownerKey)
                .foregroundStyle(DS.Color.secondary)
        case .approved:
            Label {
                Text("Approved")
            } icon: {
                Image(systemName: DS.Symbol.mailboxOK).foregroundStyle(DS.Color.done)
            }
        case .notUsedHere(let reason):
            VStack(alignment: .trailing, spacing: 2) {
                Label {
                    Text(OwnerKeyText.notUsedHere)
                } icon: {
                    Image(systemName: DS.Symbol.ownerKey).foregroundStyle(DS.Color.secondary)
                }
                Text(verbatim: reason)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Button(OwnerKeyText.setUpAgain) { model.setUpOwnerKey() }
            }
        case .refused(let reason), .unavailable(let reason):
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: reason)
                    .foregroundStyle(DS.Color.error)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Button(OwnerKeyText.setUpAgain) { model.setUpOwnerKey() }
            }
        }
    }

    /// The code, large, with "?" for why it exists.
    private func codeCard(_ code: String) -> some View {
        VStack(spacing: DS.Space.stepPart) {
            HStack(spacing: DS.Space.inline) {
                Text("Code for this Mac").font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
                HelpButton(rowLabel: "Code", text: OwnerKeyText.codeHelp)
            }
            Text(verbatim: OwnerKeyText.grouped(code))
                .font(DS.Font.enrollCode)
                .accessibilityLabel("Code " + code.map(String.init).joined(separator: " "))
            Text(OwnerKeyText.approveOnly)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.stepPart)
    }

    private func steps(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            ForEach(Array(OwnerKeyText.steps(code).enumerated()), id: \.offset) { index, text in
                Label {
                    Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: DS.Symbol.stepTodo(index + 1)).foregroundStyle(DS.Color.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var requireRow: some View {
        let required = model.ownerStatus?.required ?? false
        LabeledContent {
            if required {
                Button("Turn Off…") { model.requireOwnerKey(false) }
                    .disabled(model.requireOffPending || model.ownerKeyState != .approved)
            } else {
                Button("Require Owner Key…") { confirmRequire = true }
                    .disabled(!model.canRequireOwnerKey)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.inline) {
                    Text("Require the owner key")
                    HelpButton(rowLabel: "Require the owner key", text: OwnerKeyText.requireHelp)
                }
                if let note = OwnerKeyText.requireNote(required: required, offPending: model.requireOffPending,
                                                       canRequire: model.canRequireOwnerKey,
                                                       problem: model.requireProblem) {
                    Text(verbatim: note)
                        .font(DS.Font.caption)
                        .foregroundStyle(model.requireProblem == nil ? DS.Color.secondary : DS.Color.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Settings › Queue › Owner Key's words, here so tests pin them.
public enum OwnerKeyText {
    public static let setUp = "Set Up This Mac…"
    public static let setUpAgain = "Set Up Again…"
    /// An approved key the Pond URL's scheme doesn't take (`OwnerKeyState.notUsedHere`).
    public static let notUsedHere = "Not used on this address"
    public static let help = "The owner key lets the Pond tell your answers apart from a session's. Each Mac makes "
        + "its own key and keeps it in your Keychain; the Pond stores only its hash, and only after you approve "
        + "the Mac on Telegram."
    public static let codeHelp = "Telegram shows the code Hook made for this Mac. If the message shows another code, "
        + "or you didn't start this, tap Refuse: someone else is trying to act as you."
    public static let approveOnly = "Approve the Telegram message only if it shows this code. It expires after 10 minutes."
    public static let waiting = "Waiting for your approval on Telegram…"
    public static let requireHelp = "Once on, sessions and scripts can no longer answer, press Done or reopen as you. "
        + "It turns on only once two Macs are approved, this one among them, so you can still answer from either."
    public static let confirmTitle = "Require the owner key?"
    public static let confirmMessage = "Both Macs can act as you. Sessions and scripts will no longer be able to answer as you. Turn on?"

    /// "482 913".
    public static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    public static func steps(_ code: String) -> [String] {
        ["Open the Hook message in Telegram.", "Check it shows \(grouped(code)).", "Tap Approve. Refuse if the code differs."]
    }

    /// "studio-mac · approved 28 Oct", "studio-mac · waiting".
    public static func row(_ key: OwnerKeyRow, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let label = Sanitize.revealLine(key.label)
        guard key.status == "approved" else { return label + " · waiting" }
        let day = key.approvedAt.flatMap(Timestamp.date).map {
            $0.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated))
        }
        return label + " · approved" + (day.map { " " + $0 } ?? "")
    }

    /// The line under "Require the owner key": why it's off, what it waits for, or why it failed.
    public static func requireNote(required: Bool, offPending: Bool, canRequire: Bool, problem: String?) -> String? {
        if let problem { return problem }
        if offPending { return "Approve on Telegram to turn this off." }
        if required { return "On: only your Macs can act as you." }
        return canRequire ? nil : "Available once two Macs are approved, this one among them."
    }
}
