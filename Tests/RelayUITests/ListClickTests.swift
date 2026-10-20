import AppKit
import Testing
@testable import RelayUI

@Suite struct ListClickTests {
    @Test func leftClicksOpen() {
        #expect(ListClick.opensOnSelection(.leftMouseDown))
        #expect(ListClick.opensOnSelection(.leftMouseUp))
    }

    @Test func keysAndOtherButtonsOnlySelect() {
        let others: [NSEvent.EventType] = [.keyDown, .keyUp, .flagsChanged, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .scrollWheel, .leftMouseDragged]
        for type in others {
            #expect(!ListClick.opensOnSelection(type), "\(type.rawValue) must not open")
        }
        #expect(!ListClick.opensOnSelection(nil))
    }

    @Test func tapOnTheSelectedRowOpensOnlyFromTheList() {
        #expect(ListClick.tapOpens(openDetail: nil))
        #expect(!ListClick.tapOpens(openDetail: "a1"))
    }

    @MainActor @Test func groupingAnnouncements() {
        #expect(QueueView<FixturePanelModel>.groupingAnnouncement(.project) == "Grouped by project")
        #expect(QueueView<FixturePanelModel>.groupingAnnouncement(.urgency) == "Grouped by urgency")
    }
}
