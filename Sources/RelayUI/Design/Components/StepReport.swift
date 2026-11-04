import RelayCore
import SwiftUI

/// Design/StepReportLink: Report at the bottom right of an expanded step (0.14, owner pick 1):
/// a quiet, borderless icon and "Report" in the secondary colour, after the step's body. The
/// header keeps only the title and the chevron.
struct StepReportLink: View {
    let action: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button { action() } label: {
                Label(ProblemReport.linkTitle, systemImage: DS.Symbol.report)
            }
            .buttonStyle(.borderless)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondary)
            .help(ProblemReport.buttonHelp)
        }
    }
}

/// Design/InlineReportField: the report, open inside its step (0.14): "Problem with step 2"
/// with its "?", a field that grows to 8 lines and then scrolls, the trim line over the cap,
/// the counter past 80 %, Cancel and Send. Return adds a line, ⌘Return sends (through the key
/// router) and Esc cancels. Without an approved owner key Send holds the note and starts the
/// setup: the held caption shows under the field. A refusal shows its reason there.
public struct InlineReportField: View {
    let title: String
    let slot: StepReportSlot
    @FocusState private var focused: Bool
    /// A gallery render never takes the keys, so it is repeatable (the app never sets this).
    @Environment(\.panelGallery) private var gallery

    init(title: String, slot: StepReportSlot) {
        self.title = title
        self.slot = slot
    }

    public static let sendTitle = "Send"

    /// Send is on for a note within the cap, while nothing is in flight or held.
    public static func canSend(_ text: String, limits: TalkLimits, state: ReportBoxState) -> Bool {
        ProblemReport.canSend(text, limits: limits) && state != .sending && state != .held
    }

    /// The line under the field: held, or why the Pond refused the note.
    public static func caption(_ state: ReportBoxState) -> String? {
        switch state {
        case .held: return ProblemReport.heldCaption
        case .failed(let reason): return line(reason)
        case .idle, .sending: return nil
        }
    }

    private var text: Binding<String> {
        let slot = slot
        return Binding(get: { slot.draft }, set: { slot.onEdit($0) })
    }

    private var count: Int { ProblemReport.count(slot.draft, limits: slot.limits) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.rowLine) {
                Text(title)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(DS.Color.secondary)
                HelpButton(rowLabel: ProblemReport.menuTitle, text: ProblemReport.help)
                    .controlSize(DS.Control.inline)
            }
            MultilineField(ProblemReport.placeholder, text: text, lines: DS.Metric.fieldLines, isFocused: $focused)
                .disabled(slot.state == .held || slot.state == .sending)
                .onExitCommand { slot.onCancel() }
            LimitCaption(count: count, limit: slot.limits.report)
            if let caption = Self.caption(slot.state) {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundStyle(slot.state == .held ? DS.Color.secondary : DS.Color.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Spacer(minLength: 0)
                LimitCounter(count: count, limit: slot.limits.report)
                Button("Cancel") { slot.onCancel() }
                    .help("Cancel (Esc)")
                sendButton
            }
            .controlSize(DS.Control.inline)
        }
        .padding(.top, DS.Space.stepPart)
        .onAppear { if gallery == PanelGalleryOverrides() { focused = true } }
        .onChange(of: focused, initial: true) { _, isFocused in slot.onFocus(isFocused) }
        .onDisappear { slot.onFocus(false) }
    }

    @ViewBuilder private var sendButton: some View {
        if slot.state == .sending {
            Button {} label: {
                ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
            }
            .disabled(true)
        } else {
            Button(Self.sendTitle) { send() }
                .disabled(!Self.canSend(slot.draft, limits: slot.limits, state: slot.state))
                .help(slot.keyReady ? "Send (⌘Return)" : ProblemReport.notEnrolled)
        }
    }

    private func send() {
        guard Self.canSend(slot.draft, limits: slot.limits, state: slot.state) else { return }
        slot.onSend(slot.draft)
    }
}

/// A reported step: only the filled icon, with a tooltip and VoiceOver's label; no caption.
struct ReportedMark: View {
    var body: some View {
        Image(systemName: DS.Symbol.reported)
            .imageScale(.small)
            .foregroundStyle(DS.Color.warnText)
            .help(ProblemReport.reportedHelp)
            .accessibilityElement()
            .accessibilityLabel(ProblemReport.reportedLabel)
    }
}
