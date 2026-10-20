import Testing
@testable import RelayCore

@Suite struct ContextMenuModelTests {
    private func row(project: String = "Acme", closed: ClosedInfo? = nil, resume: String? = nil) -> AskRowModel {
        AskRowModel(id: "a1", title: "Rotate the example token", project: project, urgency: .today,
                    created: "2026-10-16T08:00:00+00:00", summary: .steps(done: 0, total: 2),
                    closed: closed, resumeCommand: resume)
    }

    @Test func openAskEntries() {
        #expect(QueueContextMenu.entries(for: row(resume: "cd '/tmp' && claude --resume 1b2c3d4e"), filter: nil) == [
            .item(title: "Open", command: .open, shortcut: "↩"),
            .item(title: "Done", command: .done, shortcut: "⌘↩"),
            .item(title: "Skip", command: .skip, shortcut: "⌘⌫"),
            .separator,
            .item(title: "Show Only Acme", command: .showOnly("Acme"), shortcut: "⌃⌘P"),
            .separator,
            .item(title: "Copy Link", command: .copyLink, shortcut: "⇧⌘L"),
            .item(title: "Copy Resume Command", command: .copyResume, shortcut: nil),
        ])
    }

    @Test func closedAskEntries() {
        let closed = ClosedInfo(status: "done", closedBy: "owner", completedAt: "2026-10-16T09:00:00+00:00")
        #expect(QueueContextMenu.entries(for: row(closed: closed, resume: "cd '/tmp' && claude --resume 1b2c3d4e"), filter: nil) == [
            .item(title: "Open", command: .open, shortcut: "↩"),
            .item(title: "Reopen", command: .reopen, shortcut: "⇧⌘R"),
            .separator,
            .item(title: "Show Only Acme", command: .showOnly("Acme"), shortcut: "⌃⌘P"),
            .separator,
            .item(title: "Copy Link", command: .copyLink, shortcut: "⇧⌘L"),
        ])
    }

    @Test func alreadyFilteredToThatProjectOffersShowAll() {
        let entries = QueueContextMenu.entries(for: row(), filter: "Acme")
        #expect(entries.contains(.item(title: "Show All Projects", command: .showAll, shortcut: "⌃⌘A")))
        #expect(!entries.contains { if case .item(_, .showOnly, _) = $0 { true } else { false } })
    }

    @Test func emptyProjectHasNoProjectEntryAndOneSeparator() {
        let entries = QueueContextMenu.entries(for: row(project: ""), filter: nil)
        #expect(entries.filter { $0 == .separator }.count == 1)
        #expect(!entries.contains { if case .item(_, .showOnly, _) = $0 { true } else { false } })
    }

    @Test func projectTitleIsSanitizedAndMiddleTruncatedButTheCommandKeepsTheRawName() {
        let long = "Quarterly planning for the public launch of the pricing page"   // 60 characters
        let entries = QueueContextMenu.entries(for: row(project: long), filter: nil)
        guard case let .item(title, command, _)? = entries.first(where: {
            if case .item(_, .showOnly, _) = $0 { true } else { false }
        }) else {
            Issue.record("no Show Only entry")
            return
        }
        #expect(command == .showOnly(long))
        let name = String(title.dropFirst("Show Only ".count))
        #expect(name.count == 40)
        #expect(name == "Quarterly planning … of the pricing page")
        let hidden = QueueContextMenu.entries(for: row(project: "Ac\u{202E}me"), filter: nil)
        #expect(hidden.contains(.item(title: "Show Only Ac⟨U+202E⟩me", command: .showOnly("Ac\u{202E}me"), shortcut: "⌃⌘P")))
    }

    @Test func middleTruncationLeavesShortTextAlone() {
        #expect(QueueContextMenu.middleTruncated("Acme", max: 40) == "Acme")
        #expect(QueueContextMenu.middleTruncated(String(repeating: "x", count: 40), max: 40).count == 40)
        #expect(QueueContextMenu.middleTruncated("abcdefghij", max: 5) == "ab…ij")
    }

    @Test func linkUsesTheRelayScheme() {
        #expect(QueueContextMenu.link(for: "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61")
                == "relay://i/6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61")
    }
}
