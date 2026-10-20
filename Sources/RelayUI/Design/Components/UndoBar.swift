import Foundation
import RelayCore
import SwiftUI

/// Design/UndoBar: "Done · <title>" with a live countdown to the undo
/// deadline and an Undo button. The title is ask text, so it goes through `line()`.
/// Keys (⌘Z) are attached by the panel, not here. While held closes are sent on quit
/// (`sending`), a labelled spinner replaces the countdown and Undo is off. The "Done." /
/// "Skipped." announcement is posted by the Store when the close is held, never here, so
/// moving between the queue and an ask doesn't repeat it.
public struct UndoBar: View {
    let undo: UndoInfo
    let sending: Bool
    let onUndo: () -> Void

    public init(undo: UndoInfo, sending: Bool = false, onUndo: @escaping () -> Void) {
        self.undo = undo
        self.sending = sending
        self.onUndo = onUndo
    }

    public var body: some View {
        // The label's seconds-left value is redrawn at each instant it changes, so
        // VoiceOver and the visible countdown agree. The explicit schedule ends at the deadline.
        TimelineView(.explicit(Self.ticks(until: undo.deadline, now: Date()))) { context in
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                    Text(Self.text(undo))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.inline)
                    if sending {
                        // Bounded by the quit-time cap on sending.
                        HStack(spacing: DS.Space.inline) {
                            ProgressView().controlSize(.mini)
                            Text(Self.sendingText)
                        }
                        .foregroundStyle(DS.Color.secondary)
                    } else {
                        // The upper bound never drops below the lower one, so the range can't invert.
                        Text(timerInterval: context.date...max(context.date, undo.deadline), countsDown: true)
                            .monospacedDigit()
                            .foregroundStyle(DS.Color.secondary)
                    }
                    Button("Undo", action: onUndo)
                        .controlSize(DS.Control.inline)
                        .disabled(sending)
                        .help("Undo (⌘Z)")
                }
                .font(DS.Font.meta)
                .padding(.horizontal, DS.Space.gutter)
                .frame(height: DS.Metric.undoBar)
                .background(DS.Color.bar)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityText(undo, sending: sending,
                                                       secondsLeft: Self.secondsLeft(until: undo.deadline, now: context.date)))
            .accessibilityAddTraits(.isButton)
            // VO-Space on the combined element runs Undo, whatever the child Button does.
            .accessibilityAction { if !sending { onUndo() } }
        }
    }

    /// The label beside the spinner while held closes are sent on quit.
    public static let sendingText = "Sending"

    /// "Done. Undo available for 10 seconds." or "Skipped. …"; the hold is `DS.Motion.undoHold`.
    /// The Store posts it once, when the close is held.
    public static func announcement(for verdict: Verdict) -> String {
        "\(word(verdict)). Undo available for \(Int(DS.Motion.undoHold)) seconds."
    }

    static func word(_ verdict: Verdict) -> String { verdict == .done ? "Done" : "Skipped" }

    /// "Done · <title>[ · +N more]" or "Skipped · …".
    public static func text(_ undo: UndoInfo) -> String {
        word(undo.verdict) + " · " + line(undo.title) + (undo.more > 0 ? " · +\(undo.more) more" : "")
    }

    /// "Done: <title>. Undo, 8 seconds left", or "Done: <title>. Sending" while sending, for VoiceOver.
    public static func accessibilityText(_ undo: UndoInfo, sending: Bool = false, secondsLeft: Int) -> String {
        let head = "\(word(undo.verdict)): \(line(undo.title)). "
        if sending { return head + sendingText }
        return head + "Undo, \(secondsLeft) \(secondsLeft == 1 ? "second" : "seconds") left"
    }

    /// Whole seconds until `deadline`, rounded up, never below 0.
    public static func secondsLeft(until deadline: Date, now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The ascending instants at which `secondsLeft(until:now:)` changes, ending at `deadline`;
    /// empty once the deadline has passed. Drives the accessibility label's redraws.
    static func ticks(until deadline: Date, now: Date) -> [Date] {
        let n = secondsLeft(until: deadline, now: now)
        return (0..<n).reversed().map { deadline.addingTimeInterval(-Double($0)) }
    }
}
