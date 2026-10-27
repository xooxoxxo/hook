import Foundation
import Testing
@testable import RelayCore

/// A flow on the source page.
private func atSource() -> WelcomeFlow {
    var flow = WelcomeFlow()
    flow.continueTapped()
    return flow
}

@Suite struct WelcomeFlowTests {
    @Test func itHasSevenPagesAndStartsOnWelcome() {
        let flow = WelcomeFlow()
        #expect(WelcomeFlow.pageCount == 7)
        #expect(WelcomeFlow.Page.allCases.map(\.number) == [1, 2, 3, 4, 5, 6, 7])
        #expect(flow.page == .welcome && !flow.starting && flow.error == nil && !flow.canGoBack)
        #expect(!flow.finished && flow.done.isEmpty && flow.skipped.isEmpty)
    }

    @Test func continueWalksThePagesInOrder() {
        var flow = atSource()
        #expect(flow.page == .source && flow.done == [.welcome] && flow.canGoBack)
        flow.startTapped(isMailbox: false)
        var seen = [flow.page]
        while flow.page != .done {
            flow.continueTapped()
            seen.append(flow.page)
        }
        #expect(seen == [.agents, .notifications, .shortcut, .testAsk, .done])
        #expect(flow.done == [.welcome, .source, .agents, .notifications, .shortcut, .testAsk])
        #expect(!flow.finished)
        flow.continueTapped()                               // Open Hook
        #expect(flow.finished && !flow.skippedSetup && flow.done.contains(.done))
    }

    @Test func anOptionalPageLeftUndoneIsSkippedNotDone() {
        var flow = atSource()
        flow.startTapped(isMailbox: false)
        flow.continueTapped(complete: false)                // agents
        #expect(flow.page == .notifications && flow.skipped == [.agents] && !flow.done.contains(.agents))
        flow.back()
        flow.continueTapped(complete: true)                 // done this time
        #expect(flow.done.contains(.agents) && flow.skipped.isEmpty)
    }

    @Test func onlyTheMiddlePagesAreOptional() {
        let optional = WelcomeFlow.Page.allCases.filter(\.optional)
        #expect(optional == [.agents, .notifications, .shortcut, .testAsk])
    }

    @Test func continueOnTheSourcePageWaitsForStart() {
        var flow = atSource()
        flow.continueTapped()
        #expect(flow.page == .source)
    }

    @Test func backGoesOnePageBackAndPushesFromTheLeading() {
        var flow = atSource()
        #expect(flow.forward)
        flow.back()
        #expect(flow.page == .welcome && !flow.forward)
        flow.back()                                         // nothing before Welcome
        #expect(flow.page == .welcome)
        flow.continueTapped()
        #expect(flow.forward)
    }

    @Test func backIsOffWhileStarting() {
        var flow = atSource()
        flow.startTapped(isMailbox: true)
        #expect(!flow.canGoBack)
        flow.back()
        #expect(flow.page == .source && flow.starting)
    }

    @Test func closingTheWindowSkipsSetup() {
        var flow = atSource()
        flow.closed()
        #expect(flow.finished && flow.skippedSetup && !flow.canGoBack)
        flow.startTapped(isMailbox: false)
        #expect(flow.page == .source)                       // nothing moves after the end
        var opened = WelcomeFlow(page: .done)
        opened.continueTapped()
        opened.closed()                                     // Open Hook closes the window too
        #expect(opened.finished && !opened.skippedSetup)
    }

    // MARK: The source page

    @Test func thisMacGoesStraightToAgents() {
        var flow = atSource()
        flow.startTapped(isMailbox: false)
        #expect(flow.page == .agents && !flow.starting && flow.done.contains(.source))
    }

    @Test func aMailboxWaitsForTheFirstList() {
        var flow = atSource()
        flow.startTapped(isMailbox: true)
        #expect(flow.page == .source && flow.starting && flow.error == nil)
        flow.firstList(ok: true, reason: nil)
        #expect(flow.page == .agents && !flow.starting)
    }

    @Test func aFailedFirstListStaysWithTheReason() {
        var flow = atSource()
        flow.startTapped(isMailbox: true)
        flow.firstList(ok: false, reason: "unauthorized")
        #expect(flow.page == .source && !flow.starting)
        #expect(flow.error == "Can't reach the Pond: unauthorized")
        flow.startTapped(isMailbox: true)
        #expect(flow.error == nil && flow.starting)        // a new Start clears the old error
    }

    @Test func aFailedSaveStaysWithTheReason() {
        var flow = atSource()
        flow.saveFailed("Couldn't save config.json: permission denied")
        #expect(flow.page == .source && !flow.starting)
        #expect(flow.error == "Couldn't save config.json: permission denied")
        flow.startTapped(isMailbox: false)
        #expect(flow.page == .agents && flow.error == nil)
        flow.saveFailed("Couldn't save config.json: late")       // after the source page, nothing changes
        #expect(flow.page == .agents && flow.error == nil && !flow.starting)
    }

    @Test func noAnswerInTenSecondsIsAnError() {
        var flow = atSource()
        flow.startTapped(isMailbox: true)
        flow.timedOut()
        #expect(flow.page == .source && !flow.starting)
        #expect(flow.error == "Can't reach the Pond: no answer within 10 seconds")
        #expect(WelcomeFlow.firstListTimeout == 10)
    }

    @Test func aConfigWrittenElsewhereMovesOnUnlessStarting() {
        var idle = atSource()
        idle.configResolved()
        #expect(idle.page == .agents)
        var starting = atSource()
        starting.startTapped(isMailbox: true)
        starting.configResolved()                          // Start's own save; wait for the list
        #expect(starting.page == .source && starting.starting)
        var welcome = WelcomeFlow()
        welcome.configResolved()                           // only the source page moves on
        #expect(welcome.page == .welcome)
    }

    @Test func lateEventsAfterTheSourcePageChangeNothing() {
        var flow = atSource()
        flow.startTapped(isMailbox: false)
        flow.timedOut()
        flow.firstList(ok: false, reason: "x")
        flow.startTapped(isMailbox: true)
        #expect(flow.page == .agents && flow.error == nil && !flow.starting)
    }

    // MARK: When it shows

    @Test func itShowsForAMissingIncompleteOrPendingConfig() {
        #expect(WelcomeFlow.showsAtLaunch(.missing))
        #expect(WelcomeFlow.showsAtLaunch(.loaded(RelayConfig())))
        #expect(WelcomeFlow.showsAtLaunch(.loaded(RelayConfig(source: .local, onboarding: "pending"))))
    }

    @Test func existingSetUpsAndBrokenFilesNeverSeeIt() {
        #expect(!WelcomeFlow.showsAtLaunch(.loaded(RelayConfig(source: .local))))
        #expect(!WelcomeFlow.showsAtLaunch(.loaded(RelayConfig(source: .local, onboarding: "done"))))
        #expect(!WelcomeFlow.showsAtLaunch(.loaded(RelayConfig(
            source: .mailbox, mailboxURL: "https://mailbox.example", tokenFile: "~/t"))))
        #expect(!WelcomeFlow.showsAtLaunch(.unreadable("not valid JSON")))
    }

    @Test func theKeyIsRemovedOnlyWhenPresentAndSetupIsOver() {
        let pending = RelayConfig(source: .local, onboarding: "pending")
        #expect(WelcomeFlow.removesOnboardingKey(finished: true, config: pending))
        #expect(WelcomeFlow.removesOnboardingKey(finished: true, config: RelayConfig(onboarding: "other")))
        #expect(!WelcomeFlow.removesOnboardingKey(finished: false, config: pending))
        #expect(!WelcomeFlow.removesOnboardingKey(finished: true, config: RelayConfig(source: .local)))
        #expect(!WelcomeFlow.removesOnboardingKey(finished: true, config: nil))   // never creates a config
    }

    @Test func theConfigReadsOnboardingLeniently() throws {
        let pending = try RelayConfig.decode(Data(#"{"source": "local", "onboarding": "pending"}"#.utf8))
        #expect(pending.onboarding == "pending" && pending.wantsOnboarding)
        let wrongType = try RelayConfig.decode(Data(#"{"source": "local", "onboarding": 1}"#.utf8))
        #expect(wrongType.onboarding == nil && !wrongType.wantsOnboarding)
        let absent = try RelayConfig.decode(Data(#"{"source": "local"}"#.utf8))
        #expect(absent.onboarding == nil)
    }
}
