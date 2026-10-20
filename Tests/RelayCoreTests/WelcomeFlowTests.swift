import Testing
@testable import RelayCore

@Suite struct WelcomeFlowTests {
    @Test func itStartsOnTheSourcePage() {
        let flow = WelcomeFlow()
        #expect(flow.page == .source && !flow.starting && flow.error == nil)
    }

    @Test func thisMacGoesStraightToReady() {
        var flow = WelcomeFlow()
        flow.startTapped(isMailbox: false)
        #expect(flow.page == .ready && !flow.starting)
    }

    @Test func aMailboxWaitsForTheFirstList() {
        var flow = WelcomeFlow()
        flow.startTapped(isMailbox: true)
        #expect(flow.page == .source && flow.starting && flow.error == nil)
        flow.firstList(ok: true, reason: nil)
        #expect(flow.page == .ready && !flow.starting)
    }

    @Test func aFailedFirstListStaysWithTheReason() {
        var flow = WelcomeFlow()
        flow.startTapped(isMailbox: true)
        flow.firstList(ok: false, reason: "unauthorized")
        #expect(flow.page == .source && !flow.starting)
        #expect(flow.error == "Can't reach the mailbox: unauthorized")
        flow.startTapped(isMailbox: true)
        #expect(flow.error == nil && flow.starting)        // a new Start clears the old error
    }

    @Test func aFailedSaveStaysWithTheReason() {
        var flow = WelcomeFlow()
        flow.saveFailed("Couldn't save config.json: permission denied")
        #expect(flow.page == .source && !flow.starting)
        #expect(flow.error == "Couldn't save config.json: permission denied")
        flow.startTapped(isMailbox: false)
        #expect(flow.page == .ready && flow.error == nil)
        flow.saveFailed("Couldn't save config.json: late")       // after ready, nothing changes
        #expect(flow.page == .ready && flow.error == nil && !flow.starting)
    }

    @Test func noAnswerInTenSecondsIsAnError() {
        var flow = WelcomeFlow()
        flow.startTapped(isMailbox: true)
        flow.timedOut()
        #expect(flow.page == .source && !flow.starting)
        #expect(flow.error == "Can't reach the mailbox: no answer within 10 seconds")
        #expect(WelcomeFlow.firstListTimeout == 10)
    }

    @Test func aConfigWrittenElsewhereMovesToReadyUnlessStarting() {
        var idle = WelcomeFlow()
        idle.configResolved()
        #expect(idle.page == .ready)
        var starting = WelcomeFlow()
        starting.startTapped(isMailbox: true)
        starting.configResolved()                          // Start's own save; wait for the list
        #expect(starting.page == .source && starting.starting)
    }

    @Test func lateEventsAfterReadyChangeNothing() {
        var flow = WelcomeFlow()
        flow.startTapped(isMailbox: false)
        flow.timedOut()
        flow.firstList(ok: false, reason: "x")
        #expect(flow.page == .ready && flow.error == nil)
    }
}
