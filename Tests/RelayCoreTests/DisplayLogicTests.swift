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
        #expect(state.tooltip == nil)
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
                        #expect(state.tooltip == (reachable ? nil : "timed out"))
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
        #expect(state.tooltip == "timed out")
    }

    @Test func fromItemsCountsNowAsks() {
        let items = [ask(instructable(urgency: "now")), ask(instructable(urgency: "whenever")), legacy(cmd: "ls")]
        let state = MenuBarState.from(items: items, reachable: true, showCount: false, offlineReason: nil)
        #expect(state == MenuBarState(count: 3, nowCount: 1, reachable: true, showCount: false, offlineReason: nil))
        #expect(state.badge == .dot)
    }
}

@Suite struct MonogramTests {
    @Test func letters() {
        #expect(Monogram.letters("Central Time") == "CT")
        #expect(Monogram.letters("Relay") == "RE")
        #expect(Monogram.letters("Acme — Public Release") == "AP")
        #expect(Monogram.letters("café") == "CA")
        #expect(Monogram.letters("acme-api") == "AA")
        #expect(Monogram.letters("🚀✨") == "?")
        #expect(Monogram.letters("") == "?")
        #expect(Monogram.letters("x") == "X")
    }

    @Test func fnvMatchesReferenceVectors() {
        #expect(Monogram.fnv1a32([]) == 0x811C_9DC5)
        #expect(Monogram.fnv1a32(Array("a".utf8)) == 0xE40C_292C)
        #expect(Monogram.fnv1a32(Array("relay".utf8)) == 0x16B4_81C2)
    }

    @Test func colorIndexIsStableAndCaseInsensitive() {
        #expect(Monogram.paletteCount == 8)
        #expect(Monogram.colorIndex("Relay") == 2)
        #expect(Monogram.colorIndex("RELAY") == 2)
        #expect(Monogram.colorIndex("Acme") == 7)
        #expect(Monogram.colorIndex("") == 5)
        for name in ["Central Time", "Acme — Public Release", "café", "🚀", "work"] {
            #expect((0..<Monogram.paletteCount).contains(Monogram.colorIndex(name)))
            #expect(Monogram.colorIndex(name) == Monogram.colorIndex(name))
        }
    }
}

@Suite struct SubLineTests {
    @Test func choicesWin() {
        let ins = instructable(reply: ReplySpec(prompt: "Which one?", choices: ["Yes", "No"]))
        #expect(SubLine.text(for: ask(ins)) == "Choose 1 of 2")
    }

    @Test func stepsWithPlaces() {
        #expect(SubLine.text(for: ask(instructable())) == "1 step")
        let three = [
            Step(action: "a", place: "Terminal"), Step(action: "b", place: "Safari"),
            Step(action: "c", place: "Terminal"),
        ]
        #expect(SubLine.text(for: ask(instructable(steps: three))) == "3 steps · Terminal, Safari")
        let four = [
            Step(action: "a", place: "Terminal"), Step(action: "b", place: "Safari"),
            Step(action: "c", place: "Settings"), Step(action: "d", place: "Keychain"),
        ]
        #expect(SubLine.text(for: ask(instructable(steps: four))) == "4 steps · Terminal, Safari +2")
        let blank = [Step(action: "a", place: "  "), Step(action: "b")]
        #expect(SubLine.text(for: ask(instructable(steps: blank))) == "2 steps")
    }

    @Test func emptyChoicesFallThroughToSteps() {
        let ins = instructable(reply: ReplySpec(prompt: "Anything else?", choices: []))
        #expect(SubLine.text(for: ask(ins)) == "1 step")
    }

    @Test func replyOnlyAndNothing() {
        let free = instructable(steps: [], reply: ReplySpec(prompt: "Which channel?", choices: nil))
        #expect(SubLine.text(for: ask(free)) == "Reply")
        #expect(SubLine.text(for: ask(instructable(steps: []))) == "")
    }

    @Test func placesAreSanitized() {
        let steps = [Step(action: "a", place: "Term\u{200B}inal")]
        #expect(SubLine.text(for: ask(instructable(steps: steps))) == "1 step · Term⟨U+200B⟩inal")
    }

    /// Review Focus 1: legacy asks (no instructable) still get a subline.
    @Test func legacyAsks() {
        #expect(SubLine.text(for: legacy(cmd: "op item get x")) == "1 step")
        #expect(SubLine.text(for: legacy(cmd: "op item get x", link: "https://example.com/x")) == "1 step")
        #expect(SubLine.text(for: legacy(link: "https://example.com/x")) == "Link")
        #expect(SubLine.text(for: legacy(cmd: "   ", link: "https://example.com/x")) == "Link")
        #expect(SubLine.text(for: legacy()) == "")
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
        #expect(try age(60) == "1m")
        #expect(try age(3599) == "59m")
        #expect(try age(3600) == "1h")
        #expect(try age(86399) == "23h")
        #expect(try age(86400) == "1d")
        #expect(try age(3 * 86400 + 5) == "3d")
        #expect(try age(-120) == "now")
    }

    @Test func unparseableIsEmpty() {
        #expect(RelativeAge.text(created: "yesterday", now: Date()) == "")
        #expect(RelativeAge.text(created: "", now: Date()) == "")
    }

    /// Review Focus 3: a Mac in Europe/Istanbul (UTC+3) shows the same age.
    @Test func ignoresTheLocalTimeZone() throws {
        let istanbul = try #require(TimeZone(identifier: "Europe/Istanbul"))
        NSTimeZone.default = istanbul
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = istanbul
        // 15:30 in Istanbul is 12:30 UTC.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 30)))
        #expect(RelativeAge.text(created: "2026-10-11T09:30:00+00:00", now: now) == "3h")
        #expect(RelativeAge.text(created: "2026-10-11T09:30:00Z", now: now) == "3h")
        #expect(RelativeAge.text(created: "2026-10-11T12:29:30+00:00", now: now) == "now")
    }
}
