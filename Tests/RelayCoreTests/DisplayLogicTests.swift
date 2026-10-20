import Foundation
import Testing
@testable import RelayCore

private let stamp = "2026-10-11T09:30:00+00:00"

private func instructable(
    urgency: String? = "today",
    steps: [Step] = [Step(action: "Open the vault")],
    reply: ReplySpec? = nil
) -> Instructable {
    Instructable(v: 1, title: "Rotate the key", urgency: urgency, steps: steps, reply: reply)
}

private func ask(_ ins: Instructable) -> WireItem {
    WireItem(
        id: UUID().uuidString.lowercased(), title: ins.title, status: "open", projectId: "Acme",
        created: stamp, updated: stamp,
        payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins))
}

/// A mailbox ask posted without --json: only why, cmd and link.
private func legacy(cmd: String? = nil, link: String? = nil) -> WireItem {
    WireItem(
        id: UUID().uuidString.lowercased(), title: "Rotate the key", status: "open", projectId: "Acme",
        created: stamp, updated: stamp,
        payload: Payload(why: "It expires Friday", cmd: cmd, link: link, instructable: nil))
}

@Suite struct MenuBarStateTests {
    @Test func defaultsShowNothing() {
        let state = MenuBarState()
        #expect(state.badge == .none)
        #expect(!state.dimmed)
        #expect(state.accessibilityLabel == "Relay, 0 waiting")
        #expect(state.tooltip == "Relay · nothing waiting")
    }

    @Test(arguments: [
        (0, 0, true, MenuBarBadge.none),
        (1, 0, true, .number(1)),
        (9, 0, true, .number(9)),
        (10, 0, true, .dot),
        (18, 1, true, .dot),
        (3, 0, false, .dot),
        (2, 0, true, .number(2)),
        (2, 2, true, .number(2)),
    ])
    func badge(count: Int, nowCount: Int, showCount: Bool, expected: MenuBarBadge) {
        let state = MenuBarState(count: count, nowCount: nowCount, showCount: showCount)
        #expect(state.badge == expected)
    }

    @Test func everyCombination() {
        for count in [0, 3] {
            for nowCount in [0, 1] where nowCount <= count {
                for reachable in [true, false] {
                    for showCount in [true, false] {
                        let state = MenuBarState(
                            count: count, nowCount: nowCount, reachable: reachable,
                            showCount: showCount, offlineReason: "timed out")
                        let badge: MenuBarBadge = count == 0 ? .none : (showCount ? .number(3) : .dot)
                        #expect(state.badge == badge)
                        #expect(state.dimmed == !reachable)
                        var label = "Relay, \(count) waiting"
                        if nowCount > 0 { label += ", 1 now" }
                        if !reachable { label += ", offline" }
                        #expect(state.accessibilityLabel == label)
                        let waiting = count == 0 ? "nothing waiting" : "3 waiting" + (nowCount > 0 ? ", 1 now" : "")
                        #expect(state.tooltip == (reachable ? "Relay · " + waiting : "Relay · offline: timed out"))
                    }
                }
            }
        }
    }

    @Test func fixedOfflineCase() {
        let state = MenuBarState(count: 3, nowCount: 1, reachable: false, showCount: true, offlineReason: "timed out")
        #expect(state.badge == .number(3))
        #expect(state.dimmed)
        #expect(state.accessibilityLabel == "Relay, 3 waiting, 1 now, offline")
        #expect(state.tooltip == "Relay · offline: timed out")
    }

    @Test func tooltipForms() {
        #expect(MenuBarState(count: 5, nowCount: 1, shortcut: "⌃⌥⌘R").tooltip == "Relay · 5 waiting, 1 now · ⌃⌥⌘R")
        #expect(MenuBarState(count: 0, shortcut: "⌃⌥⌘R").tooltip == "Relay · nothing waiting · ⌃⌥⌘R")
        #expect(MenuBarState(count: 2).tooltip == "Relay · 2 waiting")
        #expect(MenuBarState(count: 2, reachable: false, offlineReason: "a\nb", shortcut: "⌃⌥⌘R").tooltip == "Relay · offline: a⟨U+000A⟩b")
        #expect(MenuBarState(count: 2, reachable: false).tooltip == "Relay · offline")
        #expect(MenuBarState(count: 5, away: true, awaySince: "10:22").tooltip == "Relay · away since 10:22 · 5 waiting")
        #expect(MenuBarState(count: 5, away: true, shortcut: "⌃⌥⌘R", awaySince: "10:22").tooltip == "Relay · away since 10:22 · 5 waiting · ⌃⌥⌘R")
        #expect(MenuBarState(count: 0, away: true).tooltip == "Relay · away · nothing waiting")
        #expect(MenuBarState(count: 1, reachable: false, offlineReason: "x", away: true).tooltip == "Relay · offline: x")
    }

    @Test func fromItemsCountsNowAsks() {
        let items = [ask(instructable(urgency: "now")), ask(instructable(urgency: "whenever")), legacy(cmd: "ls")]
        let state = MenuBarState.from(items: items, reachable: true, showCount: false, offlineReason: nil)
        #expect(state == MenuBarState(count: 3, nowCount: 1, reachable: true, showCount: false, offlineReason: nil))
        #expect(state.badge == .dot)
    }
}

@Suite struct RelativeAgeTests {
    private func age(_ seconds: TimeInterval) throws -> String {
        let created = try #require(Timestamp.date(stamp))
        return RelativeAge.text(created: stamp, now: created.addingTimeInterval(seconds))
    }

    @Test func boundaries() throws {
        #expect(try age(0) == "now")
        #expect(try age(59) == "now")
        #expect(try age(60) == "1 min ago")
        #expect(try age(3599) == "59 min ago")
        #expect(try age(3600) == "1 h ago")
        #expect(try age(86399) == "23 h ago")
        #expect(try age(86400) == "1 d ago")
        #expect(try age(3 * 86400 + 5) == "3 d ago")
        #expect(try age(-120) == "now")
    }

    @Test func unparseableIsEmpty() {
        #expect(RelativeAge.text(created: "yesterday", now: Date()) == "")
        #expect(RelativeAge.text(created: "", now: Date()) == "")
    }

    /// A Mac in Europe/Istanbul (UTC+3) shows the same age.
    @Test func ignoresTheLocalTimeZone() throws {
        let istanbul = try #require(TimeZone(identifier: "Europe/Istanbul"))
        NSTimeZone.default = istanbul
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = istanbul
        // 15:30 in Istanbul is 12:30 UTC.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 30)))
        #expect(RelativeAge.text(created: "2026-10-11T09:30:00+00:00", now: now) == "3 h ago")
        #expect(RelativeAge.text(created: "2026-10-11T09:30:00Z", now: now) == "3 h ago")
        #expect(RelativeAge.text(created: "2026-10-11T12:29:30+00:00", now: now) == "now")
    }
}

@Suite struct ClockTextTests {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func shortTime() throws {
        let date = try #require(Timestamp.date("2026-10-11T14:32:00+00:00"))
        #expect(ClockText.time(date, locale: gb, timeZone: utc) == "14:32")
        #expect(ClockText.time("2026-10-11T09:05:00+00:00", locale: gb, timeZone: utc) == "09:05")
        #expect(ClockText.time("2026-10-11T09:05:00+03:00", locale: gb, timeZone: utc) == "06:05")
        #expect(ClockText.time("yesterday", locale: gb, timeZone: utc) == "")
    }
}

@Suite struct ClosedTextTests {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    private let at = "2026-10-11T14:32:00+00:00"

    @Test func whoAndWhen() {
        let done = ClosedText.detail(status: "done", closedBy: "owner", closedAt: at, locale: gb, timeZone: utc)
        #expect(done.hasPrefix("Done by you · 11 Oct"))
        #expect(done.hasSuffix("14:32"))
        #expect(ClosedText.detail(status: "dismissed", closedBy: nil, closedAt: at, locale: gb, timeZone: utc).hasPrefix("Skipped by you · 11 Oct"))
        #expect(ClosedText.detail(status: "done", closedBy: "session", closedAt: at, locale: gb, timeZone: utc).hasPrefix("Closed by the session · 11 Oct"))
    }

    @Test func withoutATimeOrAStatus() {
        #expect(ClosedText.detail(status: "done", closedBy: "owner", closedAt: nil, locale: gb, timeZone: utc) == "Done by you")
        #expect(ClosedText.detail(status: "done", closedBy: nil, closedAt: "yesterday", locale: gb, timeZone: utc) == "Done by you")
        #expect(ClosedText.detail(status: "open", closedBy: nil, closedAt: at, locale: gb, timeZone: utc) == "Closed")
    }
}
