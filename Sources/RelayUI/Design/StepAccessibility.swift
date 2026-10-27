import RelayCore
import SwiftUI

/// The words VoiceOver, help and Copy buttons use for steps.
public enum StepAccessibility {
    public static func hint(level: StepLevel, total: Int) -> String {
        switch level {
        case .verify: return "Step \(total) of \(total)"
        default: return "Step \(level.label) of \(total)"
        }
    }

    public static func value(_ state: StepState) -> String { state == .done ? "Done" : "Not done" }

    /// The tick's value: `value(_:)`, plus the current-step cue on the current step,
    /// so the cue sits on the one element that owns the state instead of every child of the box.
    public static func tickValue(_ state: StepState) -> String {
        state == .current ? "Not done, current step" : value(state)
    }

    public static func help(_ state: StepState) -> String {
        switch state {
        case .current: return "Mark as done (⌘T)"
        case .todo: return "Mark as done"
        case .done: return "Mark as not done"
        }
    }

    public static func parentValue(done: Int, total: Int) -> String { "\(done) of \(total) done" }

    public static func parentHelp(done: Int, total: Int) -> String {
        done == total ? "Mark all \(total) as not done" : "Mark all \(total) as done"
    }

    public static func parentLabel(number: Int, action: String, done: Int, total: Int) -> String {
        "Step \(number): \(line(action)), \(parentValue(done: done, total: total))"
    }

    /// Added to a question node's label: "Question: Which environment? Answered: Staging." or
    /// "… Not answered."
    public static func question(prompt: String, answer: Answer?) -> String {
        "Question: \(line(prompt)). " + line(AnswerDrafts.accessibilityAnswer(answer))
    }

    /// A question leaf's marker label: its action, then `question(prompt:answer:)`.
    public static func questionLabel(action: String, prompt: String, answer: Answer?) -> String {
        line(action) + ". " + question(prompt: prompt, answer: answer)
    }

    /// The caption on an optional step's row.
    public static let optionalCaption = "Optional"

    /// A label with ", optional" added for an optional step (VoiceOver, the Steps rotor).
    public static func optional(_ label: String, _ isOptional: Bool) -> String {
        isOptional ? label + ", optional" : label
    }

    /// A locked step's marker: "Step 4, locked: Check the site. Finish step 3 first."
    public static func lockedLabel(level: StepLevel, action: String, lockText: String) -> String {
        let name = level == .verify ? "Verify" : "Step \(level.label)"
        return "\(name), locked: \(line(action)). \(line(lockText))."
    }

    public static func copyLabel(level: StepLevel) -> String {
        level == .verify ? "Copy the verify command" : "Copy the command for step \(level.label)"
    }

    public static func placeText(level: StepLevel, place: String?) -> String? {
        if level == .verify { return place.map { "Verify · " + line($0) } ?? "Verify" }
        return place.map(line)
    }

    public static func markAction(_ state: StepState) -> String { state == .done ? "Mark not done" : "Mark done" }

    public static func parentAction(done: Int, total: Int) -> String {
        done == total ? "Mark all not done" : "Mark all done"
    }

    /// The step context menu's one item.
    public static func contextTitle(_ state: StepState) -> String { state == .done ? "Mark as Not Done" : "Mark as Done" }

    /// The parent row's context menu item.
    public static func parentContextTitle(done: Int, total: Int) -> String {
        done == total ? "Mark All as Not Done" : "Mark All as Done"
    }
}

extension DS.Symbol {
    /// Markers differ by shape as well as colour; sub-steps are shape-only circles.
    public static func marker(level: StepLevel, state: StepState) -> String {
        switch (level, state) {
        case (.verify, .done): return verifyDone
        case (.verify, .current): return verifyCurrent
        case (.verify, .todo): return verifyTodo
        case (.sub, .done): return subDone
        case (.sub, .current): return subCurrent
        case (.sub, .todo): return subTodo
        case (.top, .done): return stepDone
        case let (.top(n), .current): return stepCurrent(n)
        case let (.top(n), .todo): return stepTodo(n)
        }
    }
}

extension DS.Color {
    public static func marker(_ state: StepState) -> Color {
        switch state {
        case .todo: return secondary
        case .current: return accent
        case .done: return done
        }
    }
}
