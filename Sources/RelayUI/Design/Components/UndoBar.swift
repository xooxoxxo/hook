import Foundation
import RelayCore
import SwiftUI

/// Design/UndoBar (design §4.3, §4.6): "Done · <title>" with a live countdown to the undo
/// deadline and an Undo button (rule A6). The title is ask text, so it goes through `line()`.
/// Keys (⌘Z) are attached by the panel, not here.
public struct UndoBar: View {
    let undo: UndoInfo
    let onUndo: () -> Void

    public init(undo: UndoInfo, onUndo: @escaping () -> Void) {
        self.undo = undo
        self.onUndo = onUndo
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text(Self.text(undo))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.inline)
                // The upper bound never drops below the lower one, so the range can't invert.
                Text(timerInterval: Date()...max(Date(), undo.deadline), countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.secondary)
                Button("Undo", action: onUndo)
                    .controlSize(DS.Control.inline)
                    .help("Undo (⌘Z)")
            }
            .font(DS.Font.meta)
            .padding(.horizontal, DS.Space.gutter)
            .frame(height: DS.Metric.undoBar)
            .background(DS.Color.bar)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(undo, secondsLeft: Self.secondsLeft(until: undo.deadline, now: Date())))
        .onAppear { AccessibilityNotification.Announcement(Self.announcement).post() }
    }

    public static let announcement = "Done. Undo available for 10 seconds."

    static func word(_ verdict: Verdict) -> String { verdict == .done ? "Done" : "Skipped" }

    /// "Done · <title>[ · +N more]" or "Skipped · …".
    public static func text(_ undo: UndoInfo) -> String {
        word(undo.verdict) + " · " + line(undo.title) + (undo.more > 0 ? " · +\(undo.more) more" : "")
    }

    /// "Done: <title>. Undo, 8 seconds left", for VoiceOver.
    public static func accessibilityText(_ undo: UndoInfo, secondsLeft: Int) -> String {
        "\(word(undo.verdict)): \(line(undo.title)). Undo, \(secondsLeft) \(secondsLeft == 1 ? "second" : "seconds") left"
    }

    /// Whole seconds until `deadline`, rounded up, never below 0.
    public static func secondsLeft(until deadline: Date, now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }
}
