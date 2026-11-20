import RelayUI
import Foundation
import RelayCore
import SwiftUI

/// Settings › Queue › Owner Key › Devices…: every device the Pond lists, in a stock table
/// (Name, Set up, Last used; names only from an older Pond), this Mac's row marked. Revoke… goes
/// with this Mac's key when it works, else as a request the owner confirms on Telegram.
public struct DevicesSheet<Model: SettingsViewModel>: View {
    @ObservedObject var model: Model
    let onDone: () -> Void
    @State private var selection: String?
    @State private var confirm: DeviceRow?
    @Environment(\.panelGallery) private var gallery

    public init(model: Model, selection: String? = nil, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _selection = State(initialValue: selection)
    }

    private var path: DeviceRevokePath {
        OwnerDevices.revokePath(state: model.ownerKeyState, status: model.ownerStatus,
                                capabilities: model.pondCapabilities)
    }

    private var dates: Bool { OwnerDevices.showsDates(model.pondCapabilities) }

    private var rows: [DeviceRow] {
        OwnerDevices.rows(model.ownerStatus, dates: dates, now: gallery.now ?? Date(),
                          locale: gallery.locale ?? .current, timeZone: gallery.timeZone ?? .current)
    }

    private var selected: DeviceRow? { rows.first { $0.id == selection } }

    private var canRevoke: Bool {
        selected != nil && path != .unavailable && !model.revokeRequest.isActive && model.revokePendingID == nil
    }

    /// After a revoke frees a slot, a Mac without a working key can set up again.
    private var offersSetUp: Bool {
        switch model.ownerKeyState {
        case .approved, .waiting, .reading: return false
        case .notSetUp, .notUsedHere, .refused, .unavailable: break
        }
        guard model.ownerStatus != nil, !OwnerDevices.full(model.ownerStatus), !model.revokeRequest.isActive else {
            return false
        }
        if case .revoked = model.revokeRequest { return true }
        return model.setUpRefusedFull
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sheetSection) {
            HStack(spacing: DS.Space.inline) {
                Text("Devices").font(DS.Font.heading)
                HelpButton(rowLabel: "Devices", text: DevicesText.help(path: path, dates: dates))
            }
            .helpLabelStyle(.heading)
            table
                // No stripes in the empty space under the last device.
                .alternatingRowBackgrounds(.disabled)
                .frame(height: DS.Metric.devicesTableHeight)
                .accessibilityLabel("Devices")
            if case .waiting(_, _, let code, _) = model.revokeRequest { telegramCard(code) }
            if let line = statusLine {
                Text(verbatim: line.text)
                    .foregroundStyle(line.problem ? DS.Color.error : DS.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.inline) {
                Text(verbatim: OwnerDevices.slots(model.ownerStatus)).foregroundStyle(DS.Color.secondary)
                Spacer()
                if offersSetUp {
                    Button(OwnerKeyText.setUp) {
                        onDone()
                        model.setUpOwnerKey()
                    }
                }
                Button("Revoke…") { confirm = selected }
                    .disabled(!canRevoke)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .controlSize(DS.Control.form)
        }
        .padding(DS.Space.sheet)
        .frame(width: DS.Metric.devicesSheetWidth)
        .onAppear { model.refreshOwnerStatus() }
        .onDisappear { if !model.revokeRequest.isActive { model.cancelDeviceRevokeRequest() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let row = confirm {
                Button(path == .telegram ? "Ask on Telegram" : "Revoke", role: .destructive) {
                    revoke(row)
                    confirm = nil
                }
            }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            if let row = confirm { Text(verbatim: confirmMessage(row)) }
        }
    }

    @ViewBuilder private var table: some View {
        if dates {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in nameCell(row) }
                TableColumn("Set up") { row in Text(verbatim: row.setUp ?? "") }
                    .width(DS.Metric.devicesDateColumn)
                TableColumn("Last used") { row in
                    Text(verbatim: row.lastUsed ?? "").foregroundStyle(row.pending ? DS.Color.secondary : DS.Color.primary)
                }
                .width(DS.Metric.devicesDateColumn)
            }
        } else {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in nameCell(row) }
            }
        }
    }

    private func nameCell(_ row: DeviceRow) -> some View {
        HStack(spacing: DS.Space.inline) {
            Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
            if row.isThisMac { Text(DevicesText.thisMac).foregroundStyle(DS.Color.secondary) }
            if row.pending && !dates { Text(OwnerDevices.waiting).foregroundStyle(DS.Color.secondary) }
        }
    }

    /// The code Telegram repeats, large, while the request waits for the tap.
    private func telegramCard(_ code: String) -> some View {
        VStack(spacing: DS.Space.stepPart) {
            Text(DevicesText.confirmOnTelegram).font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
            Text(verbatim: OwnerKeyText.grouped(code))
                .font(DS.Font.enrollCode)
                .accessibilityLabel("Code " + code.map(String.init).joined(separator: " "))
            Text(DevicesText.tapOnlyIf)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.inline) {
                ProgressView().controlSize(DS.Control.inline).accessibilityHidden(true)
                Button("Cancel") { model.cancelDeviceRevokeRequest() }.controlSize(DS.Control.inline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.stepPart)
    }

    private var statusLine: (text: String, problem: Bool)? {
        if let problem = model.revokeProblem { return (problem, true) }
        switch model.revokeRequest {
        case .idle, .waiting: return nil
        case .sending: return (DevicesText.sending, false)
        case .revoked: return (offersSetUp ? DevicesText.revokedSetUp : DevicesText.revoked, false)
        case .ended(_, let reason): return (reason, true)
        }
    }

    private var confirmTitle: String {
        guard let row = confirm else { return "Revoke device?" }
        return "Revoke " + DevicesText.named(row) + "?"
    }

    private func confirmMessage(_ row: DeviceRow) -> String {
        switch path {
        case .telegram: return DevicesText.telegramMessage
        case .ownerKey, .unavailable:
            guard let key = model.ownerStatus?.keys.first(where: { $0.id == row.id }) else { return "" }
            return OwnerKeyText.revokeMessage(key, status: model.ownerStatus)
        }
    }

    private func revoke(_ row: DeviceRow) {
        switch path {
        case .ownerKey: model.revokeOwnerKey(row.id)
        case .telegram: model.requestDeviceRevoke(row.id)
        case .unavailable: break
        }
    }
}

/// The Devices sheet's words, here so tests pin them.
public enum DevicesText {
    public static let button = "Devices…"
    public static let chooseToRevoke = "Choose a Device to Revoke…"
    public static let thisMac = "This Mac"
    public static let confirmOnTelegram = "Confirm on Telegram"
    public static let tapOnlyIf = "Tap Revoke on Telegram only if it shows this code."
    public static let sending = "Sending the request to Telegram…"
    public static let revoked = "Device revoked."
    public static let revokedSetUp = "Device revoked. You can set up this Mac now."
    public static let telegramMessage = "This Mac has no working key, so Telegram asks you to confirm. "
        + "Tap Revoke there only if it shows the code Hook shows here."

    /// "“studio-mac” (set up 4 Nov)", so two devices with one name stay apart.
    public static func named(_ row: DeviceRow) -> String {
        "“" + row.name + "”" + (row.setUp.flatMap { $0 == "—" ? nil : " (set up " + $0 + ")" } ?? "")
    }

    public static func help(path: DeviceRevokePath, dates: Bool) -> String {
        var text = "Each device that can act as you has its own owner key. Revoke one you no longer use: "
            + "it can then no longer act as you."
        if dates { text += " Last used is updated at most once an hour." }
        switch path {
        case .ownerKey: break
        case .telegram:
            text += " This Mac has no working key, so you confirm a revoke on Telegram, comparing a code as at setup."
        case .unavailable:
            text += " This Mac has no working key, and this Pond can't confirm a revoke on Telegram. "
                + "Revoke from a device that is set up, or update the Pond."
        }
        if !dates { text += " Update the Pond to see when each device was set up and last used." }
        return text
    }
}
