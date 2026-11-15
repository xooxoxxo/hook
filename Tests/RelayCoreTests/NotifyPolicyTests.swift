import Foundation
import Testing
@testable import RelayCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// `urgency` nil makes a legacy ask (no instructable), which counts as "today".
private func ask(_ id: String, urgency: String?, project: String? = "Acme") -> WireItem {
    let instructable = urgency.map {
        Instructable(v: 1, title: "t-\(id)", why: nil, urgency: $0, steps: [], verify: nil,
                     reply: nil, links: nil, from: nil)
    }
    return WireItem(
        id: id, title: "t-\(id)", status: "open", projectId: project,
        created: "2026-10-11T09:00:00+00:00", updated: "2026-10-11T09:00:00+00:00",
        payload: Payload(why: nil, cmd: nil, link: nil, instructable: instructable))
}

@Suite struct NotifyPolicyTests {
    @Test func defaultSettingsNotifyNowAndTodayButNotWhenever() {
        var policy = NotifyPolicy(settings: NotifySettings())
        #expect(policy.add([ask("w", urgency: "whenever")], now: t0) == .none)
        #expect(policy.add([ask("n", urgency: "now")], now: t0)
                == .show(.single(id: "n", project: "Acme", title: "t-n")))
        var later = NotifyPolicy(settings: NotifySettings())
        #expect(later.add([ask("legacy", urgency: nil)], now: t0)
                == .show(.single(id: "legacy", project: "Acme", title: "t-legacy")))
    }

    @Test func eachUrgencyFollowsItsSetting() {
        let off = NotifySettings(now: false, today: false, whenever: true)
        var policy = NotifyPolicy(settings: off)
        #expect(policy.add([ask("n", urgency: "now"), ask("t", urgency: "today"), ask("l", urgency: nil)], now: t0) == .none)
        #expect(policy.add([ask("w", urgency: "whenever")], now: t0)
                == .show(.single(id: "w", project: "Acme", title: "t-w")))
    }

    @Test func aMissingProjectKeepsTheRawValueAndTitlesRelay() {
        var policy = NotifyPolicy(settings: NotifySettings())
        let action = policy.add([ask("a", urgency: "today", project: nil)], now: t0)
        #expect(action == .show(.single(id: "a", project: "", title: "t-a")))
        guard case .show(let content) = action else { return }
        #expect(content.title == "Hook")
        #expect(content.body == "t-a")
    }

    @Test func firstShowsAtOnceThenAsksWithinTheWindowFoldIntoOne() {
        var policy = NotifyPolicy(settings: NotifySettings())
        #expect(policy.add([ask("a", urgency: "today")], now: t0)
                == .show(.single(id: "a", project: "Acme", title: "t-a")))
        #expect(policy.add([ask("b", urgency: "today")], now: t0 + 1) == .scheduleFlush(at: t0 + 3))
        #expect(policy.add([ask("c", urgency: "now")], now: t0 + 2) == .none)
        #expect(policy.flush(now: t0 + 2.5) == .scheduleFlush(at: t0 + 3))   // timer fired early
        #expect(policy.flush(now: t0 + 3) == .show(.many(2)))
        #expect(policy.flush(now: t0 + 4) == .none)
    }

    @Test func oneQueuedAskFlushesAsASingle() {
        var policy = NotifyPolicy(settings: NotifySettings())
        _ = policy.add([ask("a", urgency: "today")], now: t0)
        #expect(policy.add([ask("b", urgency: "today")], now: t0 + 2) == .scheduleFlush(at: t0 + 3))
        #expect(policy.flush(now: t0 + 3) == .show(.single(id: "b", project: "Acme", title: "t-b")))
    }

    @Test func afterTheWindowASingleShowsAgain() {
        var policy = NotifyPolicy(settings: NotifySettings())
        _ = policy.add([ask("a", urgency: "today")], now: t0)
        #expect(policy.add([ask("b", urgency: "today")], now: t0 + 3.5)
                == .show(.single(id: "b", project: "Acme", title: "t-b")))
        // The window restarts from the last notification shown.
        #expect(policy.add([ask("c", urgency: "today")], now: t0 + 4) == .scheduleFlush(at: t0 + 6.5))
    }

    @Test func aBatchArrivingTogetherShowsAsMany() {
        var policy = NotifyPolicy(settings: NotifySettings())
        #expect(policy.add([ask("a", urgency: "now"), ask("b", urgency: "today"), ask("w", urgency: "whenever")], now: t0)
                == .show(.many(2)))
    }

    @Test func aLateAddFlushesWhatIsQueued() {
        var policy = NotifyPolicy(settings: NotifySettings())
        _ = policy.add([ask("a", urgency: "today")], now: t0)
        _ = policy.add([ask("b", urgency: "today")], now: t0 + 1)
        // The flush timer never ran; the next add past the due time delivers everything.
        #expect(policy.add([ask("c", urgency: "today")], now: t0 + 5) == .show(.many(2)))
    }

    @Test func turningAnUrgencyOffDropsQueuedAsks() {
        var policy = NotifyPolicy(settings: NotifySettings())
        _ = policy.add([ask("a", urgency: "today")], now: t0)
        _ = policy.add([ask("b", urgency: "today")], now: t0 + 1)
        policy.update(settings: NotifySettings(today: false))
        #expect(policy.flush(now: t0 + 3) == .none)
    }

    @Test func slideInTargetIsTheFirstNowAskWhenSlideInIsOn() {
        let items = [ask("t", urgency: "today"), ask("n1", urgency: "now"), ask("n2", urgency: "now")]
        #expect(NotifyPolicy(settings: NotifySettings(slideIn: true)).slideInTarget(items)?.id == "n1")
        #expect(NotifyPolicy(settings: NotifySettings(slideIn: false)).slideInTarget(items) == nil)
        #expect(NotifyPolicy(settings: NotifySettings(slideIn: true)).slideInTarget([ask("t", urgency: "today")]) == nil)
        // Slide-in does not depend on the "now" notification setting.
        #expect(NotifyPolicy(settings: NotifySettings(now: false, slideIn: true)).slideInTarget(items)?.id == "n1")
    }

    @Test func notifiableKeepsOnlyTheSwitchedOnUrgencies() {
        let policy = NotifyPolicy(settings: NotifySettings())   // now and today on, whenever off
        let items = [ask("n", urgency: "now"), ask("w", urgency: "whenever"), ask("l", urgency: nil)]
        #expect(policy.notifiable(items).map(\.id) == ["n", "l"])
    }

    @Test func pendingCountIsTheAsksWaitingForAFlush() {
        var policy = NotifyPolicy(settings: NotifySettings())
        _ = policy.add([ask("a", urgency: "today")], now: t0)
        #expect(policy.pendingCount == 0)
        _ = policy.add([ask("b", urgency: "today"), ask("w", urgency: "whenever")], now: t0 + 1)
        _ = policy.add([ask("c", urgency: "now")], now: t0 + 2)
        #expect(policy.pendingCount == 2)
        _ = policy.flush(now: t0 + 3)
        #expect(policy.pendingCount == 0)
    }

    @Test func titlesAndBodiesAreRevealedLines() {
        #expect(NotifyContent.single(id: "a", project: "Acme", title: "Rotate the key").title == "Acme")
        #expect(NotifyContent.single(id: "a", project: "", title: "x").title == "Hook")
        #expect(NotifyContent.single(id: "a", project: "  ", title: "x").title == "Hook")
        #expect(NotifyContent.single(id: "a", project: "Ac\u{202E}me", title: "two\nlines").title == "Ac⟨U+202E⟩me")
        #expect(NotifyContent.single(id: "a", project: "Acme", title: "two\nlines").body == "two⟨U+000A⟩lines")
        #expect(NotifyContent.many(3).title == "Hook")
        #expect(NotifyContent.many(3).body == "3 new asks")
    }

    @Test func cleanUpRemovesAsksThatLeftSentOrReopened() {
        let ids = NotificationCleanup.ids(previousOpen: ["a", "b", "c"], currentOpen: ["b", "c", "d"],
                                          sent: ["x"], reopened: ["r"])
        #expect(ids == ["a", "x", "r"])
        // A brand-new ask ("d") keeps its notification.
        #expect(!ids.contains("d"))
        #expect(NotificationCleanup.ids(previousOpen: [], currentOpen: ["n"], sent: [], reopened: []).isEmpty)
    }

    @Test func authorizationIsRequestedOnceAndOnlyWhenUndetermined() {
        #expect(NotificationAuth.shouldRequest(status: .notDetermined, requestedBefore: false))
        #expect(!NotificationAuth.shouldRequest(status: .notDetermined, requestedBefore: true))
        #expect(!NotificationAuth.shouldRequest(status: .authorized, requestedBefore: false))
        #expect(!NotificationAuth.shouldRequest(status: .denied, requestedBefore: false))
    }

    @Test func permissionMapsUNAuthorizationStatusRawValues() {
        #expect(NotificationPermission(0) == .notDetermined)
        #expect(NotificationPermission(1) == .denied)
        #expect(NotificationPermission(2) == .authorized)
        #expect(NotificationPermission(3) == .authorized)   // provisional
        #expect(NotificationPermission(4) == .authorized)   // ephemeral
        #expect(NotificationPermission(99) == .notDetermined)
    }

    @Test func soundFollowsTheSetting() {
        #expect(NotifySettings().sound)
        #expect(!NotifySettings(sound: false).sound)
    }
}

private func appendMarker(_ rev: Int, added: Int = 2, note: String = "Two more checks") -> AppendMarker {
    AppendMarker(rev: rev, at: "2026-10-11T09:0\(rev):00+00:00", note: note, firstStepID: "r\(rev)",
                 addedTopLevel: added, afterAnswer: false, firstStepIndex: rev)
}

private func ownerEvent(secondsBefore seconds: TimeInterval, actor: String = "owner") -> Event {
    Event(seq: 1, itemId: "a", kind: "answer", actor: actor, text: "{}",
          at: Timestamp.string(t0.addingTimeInterval(-seconds)))
}

/// One notification when the session adds steps to an open ask (Task 19).
@Suite struct StepsAddedNotifyTests {
    @Test func stepsAddedShowsAtOnce() {
        var policy = NotifyPolicy(settings: NotifySettings())
        let content = NotifyContent.stepsAdded(id: "a", project: "Acme", title: "t-a", count: 2, note: "Two more checks",
                                               quiet: false)
        // A new ask was just shown: the added steps are not folded into the next "N new asks".
        #expect(policy.add([ask("b", urgency: "today")], now: t0) == .show(.single(id: "b", project: "Acme", title: "t-b")))
        #expect(policy.stepsAdded(ask("a", urgency: "today"), content: content) == .show(content))
        #expect(policy.add([ask("c", urgency: "today")], now: t0 + 1) == .scheduleFlush(at: t0 + 3))
        #expect(policy.pendingCount == 1)
        #expect(content.title == "2 steps added: t-a")
        #expect(content.body == "Two more checks")
        let one = NotifyContent.stepsAdded(id: "a", project: "", title: "Line\none", count: 1, note: "a\u{202E}b", quiet: false)
        #expect(one.title == "1 step added: Line⟨U+000A⟩one")
        #expect(one.body == "a⟨U+202E⟩b")
        // Urgency settings apply as for the ask itself.
        var whenever = NotifyPolicy(settings: NotifySettings())
        #expect(whenever.stepsAdded(ask("w", urgency: "whenever"), content: content) == .none)
    }

    @Test func stepsAddedQuietAfterRecentAct() {
        let item = ask("a", urgency: "today")
        let content = NotifyContent.stepsAdded(item, markers: [appendMarker(2)], events: [ownerEvent(secondsBefore: 60)],
                                               now: t0)
        #expect(content == .stepsAdded(id: "a", project: "Acme", title: "t-a", count: 2, note: "Two more checks", quiet: true))
        #expect(content?.sound(true) == false)
        #expect(NotifyContent.stepsAdded(item, markers: [appendMarker(2)], events: [ownerEvent(secondsBefore: 119)],
                                         now: t0)?.sound(true) == false)
    }

    @Test func stepsAddedRingsOtherwise() {
        let item = ask("a", urgency: "today")
        for events in [[], [ownerEvent(secondsBefore: 121)], [ownerEvent(secondsBefore: 10, actor: "session")]] {
            let content = NotifyContent.stepsAdded(item, markers: [appendMarker(2)], events: events, now: t0)
            #expect(content?.sound(true) == true)
            #expect(content?.sound(false) == false)
        }
        #expect(NotifyContent.single(id: "a", project: "", title: "t").sound(true))
    }

    @Test func noNotificationOnFirstLoad() {
        var watch = AppendWatch()
        let item = ask("a", urgency: "today")
        let fresh = watch.observe("a", markers: [appendMarker(2), appendMarker(3, added: 1)])
        #expect(NotifyContent.stepsAdded(item, markers: fresh, events: [], now: t0) == nil)
    }

    @Test func oneNotificationPerMarker() {
        var watch = AppendWatch()
        let item = ask("a", urgency: "today")
        _ = watch.observe("a", markers: [])
        let first = watch.observe("a", markers: [appendMarker(2)])
        #expect(NotifyContent.stepsAdded(item, markers: first, events: [], now: t0)?.title == "2 steps added: t-a")
        #expect(NotifyContent.stepsAdded(item, markers: watch.observe("a", markers: [appendMarker(2)]), events: [],
                                         now: t0) == nil)
        // Two appends seen in one poll: one notification, the counts summed, the newest note.
        let both = watch.observe("a", markers: [appendMarker(2), appendMarker(3, added: 1, note: "One more"),
                                                appendMarker(4, added: 1, note: "And the last")])
        #expect(NotifyContent.stepsAdded(item, markers: both, events: [], now: t0)
            == .stepsAdded(id: "a", project: "Acme", title: "t-a", count: 2, note: "And the last", quiet: false))
    }
}
