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
        #expect(content.title == "Relay")
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
        #expect(NotifyContent.single(id: "a", project: "", title: "x").title == "Relay")
        #expect(NotifyContent.single(id: "a", project: "  ", title: "x").title == "Relay")
        #expect(NotifyContent.single(id: "a", project: "Ac\u{202E}me", title: "two\nlines").title == "Ac⟨U+202E⟩me")
        #expect(NotifyContent.single(id: "a", project: "Acme", title: "two\nlines").body == "two⟨U+000A⟩lines")
        #expect(NotifyContent.many(3).title == "Relay")
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
