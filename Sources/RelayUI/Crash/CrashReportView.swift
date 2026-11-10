import RelayCore
import SwiftUI

/// The crash report window's content (Review… on the crash bar): where it goes, exactly what
/// is sent, and the send. Nothing leaves this Mac until the primary button: My Pond files a
/// Hook bug, GitHub opens a prefilled issue for the owner to submit. The window is the app's
/// own (like Settings), not a sheet on the panel; closing it is Cancel.
public struct CrashReportView<Model: PanelViewModel>: View {
    @ObservedObject var model: Model
    @Environment(\.panelGallery) private var gallery

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        if let sheet = model.crashSheet {
            content(sheet)
        }
    }

    private func content(_ sheet: CrashSheetModel) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sheetSection) {
            header(sheet)
            target(sheet)
            if let text = sheet.matchText { callout(sheet, text) }
            preview(sheet)
            if case .failed(let reason) = sheet.send {
                Label(reason, systemImage: DS.Symbol.warning)
                    .font(DS.Font.prose)
                    .foregroundStyle(DS.Color.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer(sheet)
        }
        .padding(DS.Space.sheet)
        .frame(width: DS.Metric.crashReportWidth)
    }

    private func header(_ sheet: CrashSheetModel) -> some View {
        HStack(alignment: .top, spacing: DS.Space.inline) {
            Image(systemName: DS.Symbol.warning)
                .font(DS.Font.sheetSymbol)
                .foregroundStyle(DS.Color.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                Text(CrashSheetModel.title).font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.subtitle(sheet.summary, locale: gallery.locale ?? .current, timeZone: gallery.timeZone ?? .current))
                    .font(DS.Font.prose)
                    .foregroundStyle(DS.Color.secondary)
            }
        }
    }

    /// "Send to": a segmented control while My Pond is offered, else GitHub as text.
    @ViewBuilder private func target(_ sheet: CrashSheetModel) -> some View {
        HStack(spacing: DS.Space.inline) {
            Text("Send to:")
            if sheet.targets.count > 1 {
                Picker("Send to", selection: Binding(get: { sheet.target }, set: { model.setCrashTarget($0) })) {
                    ForEach(sheet.targets, id: \.self) { Text(CrashSheetModel.targetName($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(sheet.sending)
            } else {
                Text(CrashSheetModel.targetName(sheet.target)).foregroundStyle(DS.Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(DS.Font.prose)
    }

    /// What GitHub knows about the signature, and the clipboard note for a trimmed link.
    private func callout(_ sheet: CrashSheetModel, _ text: String) -> some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                if sheet.checking {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                } else {
                    Image(systemName: Self.calloutSymbol(sheet.match)).foregroundStyle(DS.Color.accent)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                    if let secondary = sheet.secondaryTitle {
                        // GitHub couldn't be searched: look by hand; Open New Issue is the primary.
                        Button(secondary) { model.checkExistingCrashIssue() }
                            .controlSize(DS.Control.inline)
                    }
                    if let note = sheet.trimNote {
                        Text(note)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(DS.Font.prose)
        }
        .accessibilityElement(children: .contain)
    }

    static func calloutSymbol(_ match: IssueMatch?) -> String {
        switch match {
        case .closedFixed?: return DS.Symbol.update
        case .unavailable?: return DS.Symbol.offline
        default: return DS.Symbol.info
        }
    }

    private func preview(_ sheet: CrashSheetModel) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            HStack(spacing: DS.Space.inline) {
                Text("What's sent").font(DS.Font.heading)
                HelpButton(rowLabel: "What's sent", text: CrashSheetModel.reportHelp)
                Spacer(minLength: 0)
                Text(sheet.countText).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
            }
            .helpLabelStyle(.heading)
            ScrollView {
                ReportPreview(text: sheet.preview)
            }
            .frame(height: DS.Metric.reportPreview)
            .background(DS.Color.codeFill, in: .rect(cornerRadius: DS.Metric.codeRadius))
            .accessibilityLabel("Crash report preview")
        }
    }

    /// Copy and Show in Finder as icon buttons on the left, then Cancel and the primary button.
    private func footer(_ sheet: CrashSheetModel) -> some View {
        HStack(spacing: DS.Space.inline) {
            IconButton(DS.Symbol.copy, label: "Copy", help: "Copy the report") { model.copyCrashReport() }
            IconButton(DS.Symbol.reveal, label: "Show in Finder",
                       help: sheet.summary.reportFile == nil ? "No crash file: Hook quit without one"
                           : "Show the crash file in Finder") { model.showCrashReportInFinder() }
                .disabled(sheet.summary.reportFile == nil)
            Spacer(minLength: 0)
            if sheet.sending {
                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
            }
            Button("Cancel") { model.closeCrashSheet() }
                .keyboardShortcut(.cancelAction)
            Button(sheet.primaryTitle) { model.sendCrashReport() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sheet.sending || sheet.checking)
        }
        .controlSize(DS.Control.form)
    }

    /// "Hook quit unexpectedly · 15 Oct 2026 at 22:14", or "Hook was closed: … · …".
    static func subtitle(_ summary: CrashSummary, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return CrashBar.title(CrashOffer(summary: summary)) + " · " + formatter.string(from: summary.when)
    }
}
