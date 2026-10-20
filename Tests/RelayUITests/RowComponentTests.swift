import RelayCore
import Testing
@testable import RelayUI

private func row(_ summary: RowSummary = .steps(done: 2, total: 8), urgency: Urgency = .now, project: String = "Acme",
                 title: String = "Renew the staging certificate", draft: Bool = false) -> AskRowModel {
    AskRowModel(id: "a1", title: title, project: project, urgency: urgency, created: "2026-10-16T06:40:00Z",
                summary: summary, hasDraft: draft)
}

@Suite @MainActor struct RowComponentTests {
    @Test func askRowSentence() {
        #expect(AskRow.accessibilityText(row: row(), age: "3 h ago")
            == "Now. Renew the staging certificate. Acme, 3 h ago. 2 of 8 steps done")
        #expect(AskRow.accessibilityText(row: row(draft: true), age: "3 h ago")
            == "Now. Renew the staging certificate. Acme, 3 h ago. 2 of 8 steps done. Unsent reply")
        #expect(AskRow.accessibilityText(row: row(.choose(3), urgency: .whenever), age: "1 d ago")
            == "Whenever. Renew the staging certificate. Acme, 1 d ago. Choose 1 of 3")
        #expect(AskRow.accessibilityText(row: row(.none, urgency: .unknown("so\non"), project: ""), age: "now")
            == "so⟨U+000A⟩on. Renew the staging certificate. No project, now")
    }

    /// The top row shows the symbol and word for Now and Today, only the symbol under an Urgency
    /// header, nothing for Whenever, and an unknown urgency's raw string either way.
    @Test func cardUrgencyMark() {
        #expect(CardUrgency.mark(.now, headerNamesIt: false) == .symbolAndWord)
        #expect(CardUrgency.mark(.today, headerNamesIt: false) == .symbolAndWord)
        #expect(CardUrgency.mark(.whenever, headerNamesIt: false) == .hidden)
        #expect(CardUrgency.mark(.now, headerNamesIt: true) == .symbol)
        #expect(CardUrgency.mark(.today, headerNamesIt: true) == .symbol)
        #expect(CardUrgency.mark(.whenever, headerNamesIt: true) == .hidden)
        #expect(CardUrgency.mark(.unknown("soon"), headerNamesIt: false) == .raw)
        #expect(CardUrgency.mark(.unknown("soon"), headerNamesIt: true) == .raw)
    }

    @Test func onlyUrgencyHeadersNameTheUrgency() {
        #expect(QueueView<FixturePanelModel>.headerNamesUrgency(QueueSection(header: .urgency(.now), items: [])))
        #expect(QueueView<FixturePanelModel>.headerNamesUrgency(QueueSection(header: .urgency(.whenever), items: [])))
        #expect(!QueueView<FixturePanelModel>.headerNamesUrgency(QueueSection(header: .project("Acme"), items: [])))
        #expect(!QueueView<FixturePanelModel>.headerNamesUrgency(QueueSection(header: nil, items: [])))
    }

    /// VoiceOver keeps the urgency word and the full age, though the top row shows less.
    @Test func voiceOverKeepsUrgencyAndFullAge() {
        #expect(AskRow.accessibilityText(row: row(.steps(done: 0, total: 2), urgency: .whenever), age: "2 d ago")
            == "Whenever. Renew the staging certificate. Acme, 2 d ago. 2 steps")
        #expect(AskRow.accessibilityText(row: row(.steps(done: 0, total: 2), urgency: .today), age: "5 min ago")
            == "Today. Renew the staging certificate. Acme, 5 min ago. 2 steps")
    }

    @Test func askRowReadsTheSubline() {
        #expect(AskRow.accessibilityText(row: row(.steps(done: 0, total: 4), urgency: .today), age: "now")
            == "Today. Renew the staging certificate. Acme, now. 4 steps")
        var choose = row(.steps(done: 0, total: 1), urgency: .today)
        choose.subline = "Choose 1 of 3"
        #expect(AskRow.accessibilityText(row: choose, age: "now")
            == "Today. Renew the staging certificate. Acme, now. Choose 1 of 3")
    }

    @Test func askRowSanitizesTitleAndProject() {
        let text = AskRow.accessibilityText(row: row(project: "Ac\u{202E}me", title: "T\nX"), age: "now")
        #expect(text == "Now. T⟨U+000A⟩X. Ac⟨U+202E⟩me, now. 2 of 8 steps done")
    }

    @Test func titleHelpOnlyForLongTitles() {
        #expect(AskRow.titleHelp(String(repeating: "a", count: 70)) == nil)
        #expect(AskRow.titleHelp(String(repeating: "a", count: 71)) == String(repeating: "a", count: 71))
        #expect(AskRow.titleHelp(String(repeating: "a", count: 70) + "\n") == String(repeating: "a", count: 70) + "⟨U+000A⟩")
    }

    @Test func sectionHeaderSentence() {
        #expect(SectionHeader.accessibilityText(name: "Acme", count: 3) == "Acme, 3 asks")
        #expect(SectionHeader.accessibilityText(name: "Now", count: 1) == "Now, 1 ask")
        #expect(SectionHeader.accessibilityText(name: "", count: 2) == "No project, 2 asks")
        #expect(SectionHeader.displayName("") == "No project")
        #expect(SectionHeader.displayName("A\tB") == "A⟨U+0009⟩B")
    }

    @Test func closedRowAndHeader() {
        #expect(ClosedAskRow.accessibilityText(row: row(title: "Store the key"), closedLine: "Done 5 min ago")
            == "Store the key. Done 5 min ago")
        #expect(ClosedGroupHeader.accessibilityText(count: 1) == "Recently closed, 1 ask")
        #expect(ClosedGroupHeader.accessibilityText(count: 2) == "Recently closed, 2 asks")
    }

    @Test func emptyLine() {
        #expect(EmptyListLine.text(project: nil) == "Nothing waiting")
        #expect(EmptyListLine.text(project: "Acme") == "Nothing waiting in Acme")
        #expect(EmptyListLine.text(project: "") == "Nothing waiting in No project")
    }

    @Test func showOnlyActionTitle() {
        #expect(AskRow.showOnlyTitle(project: "Acme") == "Show only Acme")
        #expect(AskRow.showOnlyTitle(project: "") == nil)
    }
}
