import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

@Suite @MainActor struct StepAccessibilityTests {
    @Test func hints() {
        #expect(StepAccessibility.hint(level: .top(3), total: 5) == "Step 3 of 5")
        #expect(StepAccessibility.hint(level: .sub(3, 1), total: 5) == "Step 3b of 5")
        #expect(StepAccessibility.hint(level: .verify, total: 6) == "Step 6 of 6")
    }

    @Test func valuesAndHelp() {
        #expect(StepAccessibility.value(.done) == "Done")
        #expect(StepAccessibility.value(.current) == "Not done")
        #expect(StepAccessibility.value(.todo) == "Not done")
        #expect(StepAccessibility.tickValue(.current) == "Not done, current step")
        #expect(StepAccessibility.tickValue(.todo) == "Not done")
        #expect(StepAccessibility.tickValue(.done) == "Done")
        #expect(StepAccessibility.help(.current) == "Mark as done (⌘T)")
        #expect(StepAccessibility.help(.todo) == "Mark as done")
        #expect(StepAccessibility.help(.done) == "Mark as not done")
    }

    @Test func parents() {
        #expect(StepAccessibility.parentValue(done: 2, total: 3) == "2 of 3 done")
        #expect(StepAccessibility.parentHelp(done: 2, total: 3) == "Mark all 3 as done")
        #expect(StepAccessibility.parentHelp(done: 3, total: 3) == "Mark all 3 as not done")
        #expect(StepAccessibility.parentLabel(number: 3, action: "Create\nthe app", done: 2, total: 3)
            == "Step 3: Create⟨U+000A⟩the app, 2 of 3 done")
    }

    @Test func copyLabelsAndPlaces() {
        #expect(StepAccessibility.copyLabel(level: .top(3)) == "Copy the command for step 3")
        #expect(StepAccessibility.copyLabel(level: .sub(3, 1)) == "Copy the command for step 3b")
        #expect(StepAccessibility.copyLabel(level: .verify) == "Copy the verify command")
        #expect(StepAccessibility.placeText(level: .verify, place: "Mac terminal") == "Verify · Mac terminal")
        #expect(StepAccessibility.placeText(level: .verify, place: nil) == "Verify")
        #expect(StepAccessibility.placeText(level: .top(1), place: "Team\tchat") == "Team⟨U+0009⟩chat")
        #expect(StepAccessibility.placeText(level: .sub(1, 0), place: nil) == nil)
    }

    @Test func markers() {
        #expect(DS.Symbol.marker(level: .top(3), state: .todo) == "3.circle")
        #expect(DS.Symbol.marker(level: .top(3), state: .current) == "3.circle.fill")
        #expect(DS.Symbol.marker(level: .top(3), state: .done) == DS.Symbol.stepDone)
        #expect(DS.Symbol.marker(level: .sub(3, 0), state: .todo) == DS.Symbol.subTodo)
        #expect(DS.Symbol.marker(level: .sub(3, 0), state: .current) == DS.Symbol.subCurrent)
        #expect(DS.Symbol.marker(level: .sub(3, 0), state: .done) == DS.Symbol.subDone)
        #expect(DS.Symbol.marker(level: .verify, state: .todo) == DS.Symbol.verifyTodo)
        #expect(DS.Symbol.marker(level: .verify, state: .current) == DS.Symbol.verifyCurrent)
        #expect(DS.Symbol.marker(level: .verify, state: .done) == DS.Symbol.verifyDone)
        #expect(DS.Color.marker(.todo) == DS.Color.secondary)
        #expect(DS.Color.marker(.current) == DS.Color.accent)
        #expect(DS.Color.marker(.done) == DS.Color.done)
        #expect(TickButton.scale(for: .sub(1, 0)) == .medium)
        #expect(TickButton.scale(for: .top(1)) == .large)
        #expect(TickButton.scale(for: .verify) == .large)
    }

    @Test func customActionNames() {
        #expect(StepAccessibility.markAction(.done) == "Mark not done")
        #expect(StepAccessibility.markAction(.todo) == "Mark done")
        #expect(StepAccessibility.parentAction(done: 3, total: 3) == "Mark all not done")
        #expect(StepAccessibility.parentAction(done: 1, total: 3) == "Mark all done")
    }

    @Test func contextMenuTitles() {
        #expect(StepAccessibility.contextTitle(.done) == "Mark as Not Done")
        #expect(StepAccessibility.contextTitle(.current) == "Mark as Done")
        #expect(StepAccessibility.contextTitle(.todo) == "Mark as Done")
        #expect(StepAccessibility.parentContextTitle(done: 3, total: 3) == "Mark All as Not Done")
        #expect(StepAccessibility.parentContextTitle(done: 1, total: 3) == "Mark All as Done")
    }
}
