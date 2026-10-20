import Testing
@testable import RelayCore

@Suite struct PanelNavigationTests {
    @Test func principleOneLoop() {
        var nav = PanelNavigation(listSelection: "a")
        var order = ["a", "b", "c"]
        nav.open("a")
        for id in ["a", "b", "c"] {
            #expect(nav.selectedID == id)
            nav.afterClose(id, visibleOrder: order, setting: .next, inDetail: true)
            order.removeAll { $0 == id }
        }
        #expect(nav.selectedID == nil)
        #expect(nav.listSelection == nil)
    }

    @Test func openAndBackKeepTheRow() {
        var nav = PanelNavigation(listSelection: "a")
        nav.open("b")
        #expect(nav == PanelNavigation(listSelection: "b", selectedID: "b"))
        nav.back()
        #expect(nav == PanelNavigation(listSelection: "b", selectedID: nil))
    }

    @Test func anAskOutsideTheFilterLeavesTheRow() {
        var nav = PanelNavigation(listSelection: "a")
        nav.open("x", listed: false)
        #expect(nav == PanelNavigation(listSelection: "a", selectedID: "x"))
        nav.back()
        #expect(nav.listSelection == "a")
    }

    @Test func afterCloseToTheQueueSelectsTheNextRow() {
        var nav = PanelNavigation(listSelection: "b", selectedID: "b")
        nav.afterClose("b", visibleOrder: ["a", "b", "c"], setting: .queue, inDetail: true)
        #expect(nav == PanelNavigation(listSelection: "c", selectedID: nil))
    }

    @Test func afterCloseFromTheListStaysInTheList() {
        var nav = PanelNavigation(listSelection: "c")
        nav.afterClose("c", visibleOrder: ["a", "b", "c"], setting: .next, inDetail: false)
        #expect(nav == PanelNavigation(listSelection: "b", selectedID: nil))
    }

    @Test func afterClosingTheLastAskTheDetailCloses() {
        var nav = PanelNavigation(listSelection: "a", selectedID: "a")
        nav.afterClose("a", visibleOrder: ["a"], setting: .next, inDetail: true)
        #expect(nav == PanelNavigation(listSelection: nil, selectedID: nil))
    }

    @Test func afterClosingAnAskOutsideTheFilterTheFirstShownOpens() {
        var nav = PanelNavigation(listSelection: "b", selectedID: "x")
        nav.afterClose("x", visibleOrder: ["a", "b"], setting: .next, inDetail: true)
        #expect(nav == PanelNavigation(listSelection: "a", selectedID: "a"))
    }

    @Test func settleKeepsAShownRowElseTakesTheFirst() {
        var nav = PanelNavigation(listSelection: "b")
        nav.settle(visibleOrder: ["a", "b"], closedOrder: [])
        #expect(nav.listSelection == "b")
        nav.settle(visibleOrder: ["a"], closedOrder: ["b"])
        #expect(nav.listSelection == "b")
        nav.settle(visibleOrder: ["a"], closedOrder: [])
        #expect(nav.listSelection == "a")
        nav.settle(visibleOrder: [], closedOrder: [])
        #expect(nav.listSelection == nil)
        nav.filterChanged(visibleOrder: ["c", "d"], closedOrder: [])
        #expect(nav.listSelection == "c")
    }

    @Test func undoRestoredSelectsWhenShownAndInTheList() {
        var nav = PanelNavigation(listSelection: "b")
        nav.undoRestored("a", visibleOrder: ["a", "b"])
        #expect(nav.listSelection == "a")
        nav.undoRestored("x", visibleOrder: ["a", "b"])
        #expect(nav.listSelection == "a")
        var inDetail = PanelNavigation(listSelection: "b", selectedID: "b")
        inDetail.undoRestored("a", visibleOrder: ["a", "b"])
        #expect(inDetail == PanelNavigation(listSelection: "b", selectedID: "b"))
    }

    @Test func neighbours() {
        let nav = PanelNavigation()
        #expect(nav.neighbours(of: "b", visibleOrder: ["a", "b", "c"], closedOrder: []) == (.ask("a"), .ask("c")))
        #expect(nav.neighbours(of: "a", visibleOrder: ["a", "b"], closedOrder: []) == (.end, .ask("b")))
        #expect(nav.neighbours(of: "b", visibleOrder: ["a", "b"], closedOrder: []) == (.ask("a"), .end))
        #expect(nav.neighbours(of: "y", visibleOrder: ["a"], closedOrder: ["x", "y"]) == (.ask("x"), .end))
        #expect(nav.neighbours(of: "z", visibleOrder: ["a"], closedOrder: ["x"]) == (.outsideFilter, .outsideFilter))
    }
}
