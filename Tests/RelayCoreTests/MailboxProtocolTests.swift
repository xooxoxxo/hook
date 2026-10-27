import Foundation
import Testing
@testable import RelayCore

private let key = "mailbox:mailbox.example:8790#personal"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func check(level: Int?, key: String = key, at date: Date = t0) -> MailboxCheck {
    MailboxCheck(sourceKey: key, result: level.map { .version(MailboxVersion(version: "0.9.1", level: $0)) }
        ?? .failed(reason: "the mailbox didn't answer"), checkedAt: date)
}

@Suite struct MailboxProtocolTests {
    @Test func featuresAndTheirLevels() {
        #expect(MailboxFeature.answers.minimumLevel == 2)
        #expect(MailboxFeature.blocking.minimumLevel == 3)
        #expect(MailboxFeature.optional.minimumLevel == 4)
        #expect(MailboxFeature.fileLinks.minimumLevel == 4)
        #expect(MailboxProtocol.current == 4)
        #expect(MailboxProtocol.missingFeatures(level: 1) == [.answers, .blocking, .optional, .fileLinks])
        #expect(MailboxProtocol.missingFeatures(level: 2) == [.blocking, .optional, .fileLinks])
        #expect(MailboxProtocol.missingFeatures(level: 3) == [.optional, .fileLinks])
        #expect(MailboxProtocol.missingFeatures(level: 4) == [])
    }

    @Test func featureListReadsAsASentence() {
        #expect(MailboxProtocol.featureList([.blocking]) == "blocking steps")
        #expect(MailboxProtocol.featureList([.blocking, .answers]) == "per-step answers and blocking steps")
        #expect(MailboxProtocol.featureList([.optional, .answers, .blocking])
            == "per-step answers, blocking steps and optional steps")
        #expect(MailboxProtocol.featureList([.fileLinks, .optional]) == "optional steps and file links")
        #expect(MailboxProtocol.featureList([.fileLinks, .blocking, .optional, .answers])
            == "per-step answers, blocking steps, optional steps and file links")
        #expect(MailboxProtocol.featureList([]) == "")
    }

    @Test(arguments: [(1, MailboxCompatibility.mailboxOlder(missing: [.answers, .blocking, .optional, .fileLinks])),
                      (2, .mailboxOlder(missing: [.blocking, .optional, .fileLinks])),
                      (3, .mailboxOlder(missing: [.optional, .fileLinks])),
                      (4, .ok), (5, .mailboxNewer)])
    func compatibility(_ level: Int, _ expected: MailboxCompatibility) {
        #expect(MailboxCompatibility.evaluate(level: level) == expected)
    }

    @Test func anOlderHookOnlyMissesWhatItUses() {
        #expect(MailboxCompatibility.evaluate(level: 1, hookLevel: 2) == .mailboxOlder(missing: [.answers]))
        #expect(MailboxCompatibility.evaluate(level: 3, hookLevel: 2) == .mailboxNewer)
    }

    @Test func versionDecodesTheProtocolKey() throws {
        let data = Data(#"{"service":"mailbox","version":"0.9.1","protocol":2,"extra":true}"#.utf8)
        let version = try JSONDecoder().decode(MailboxVersion.self, from: data)
        #expect(version == MailboxVersion(service: "mailbox", version: "0.9.1", level: 2))
        let bare = try JSONDecoder().decode(MailboxVersion.self, from: Data(#"{"protocol":1,"version":7}"#.utf8))
        #expect(bare == MailboxVersion(level: 1))
    }

    @Test func versionLine() {
        #expect(MailboxVersionLine.line(check(level: 4), checking: false)
            == MailboxVersionLine(text: "0.9.1 · level 4", state: .ok))
        let behind = MailboxVersionLine.line(check(level: 2), checking: false)
        #expect(behind.state == .needsUpdate)
        #expect(behind.badge == "Needs an update")
        #expect(MailboxVersionLine.line(check(level: 3), checking: false).state == .needsUpdate)
        #expect(MailboxVersionLine.line(check(level: 5), checking: false).state == .hookOlder)
        let legacy = MailboxCheck(sourceKey: key, result: .version(.legacy), checkedAt: t0)
        #expect(MailboxVersionLine.line(legacy, checking: false).text == "level 1")
        #expect(MailboxVersionLine.line(check(level: nil), checking: false)
            == MailboxVersionLine(text: "Couldn't check: the mailbox didn't answer", state: .failed))
        #expect(MailboxVersionLine.line(check(level: 3), checking: true).state == .checking)
        #expect(MailboxVersionLine.line(nil, checking: false).text == "Not checked yet")
    }

    @Test func versionLineRevealsHiddenCharactersInTheServersVersion() {
        let odd = MailboxCheck(sourceKey: key, result: .version(MailboxVersion(version: "1.0\u{202E}x", level: 3)),
                               checkedAt: t0)
        #expect(!MailboxVersionLine.line(odd, checking: false).text.contains("\u{202E}"))
    }
}

@Suite struct MailboxCheckScheduleTests {
    @Test func firstConnectAndANewSourceAreDue() {
        #expect(MailboxCheckSchedule.isDue(last: nil, sourceKey: key, reachable: true, becameReachable: true, now: t0))
        let other = check(level: 3, key: "mailbox:other.example#personal")
        #expect(MailboxCheckSchedule.isDue(last: other, sourceKey: key, reachable: true, becameReachable: false, now: t0))
    }

    @Test func thenAtMostEveryThirtyMinutes() {
        let last = check(level: 3)
        #expect(!MailboxCheckSchedule.isDue(last: last, sourceKey: key, reachable: true, becameReachable: false,
                                            now: t0.addingTimeInterval(29 * 60)))
        #expect(MailboxCheckSchedule.isDue(last: last, sourceKey: key, reachable: true, becameReachable: false,
                                           now: t0.addingTimeInterval(30 * 60)))
    }

    @Test func aReconnectIsDue() {
        #expect(MailboxCheckSchedule.isDue(last: check(level: 3), sourceKey: key, reachable: true, becameReachable: true,
                                           now: t0.addingTimeInterval(60)))
    }

    @Test func neverWhileUnreachableOrOutsideMailboxMode() {
        #expect(!MailboxCheckSchedule.isDue(last: nil, sourceKey: key, reachable: false, becameReachable: false, now: t0))
        #expect(!MailboxCheckSchedule.isDue(last: nil, sourceKey: SourceKey.local, reachable: true, becameReachable: true, now: t0))
        #expect(!MailboxCheckSchedule.isDue(last: nil, sourceKey: SourceKey.none, reachable: true, becameReachable: true, now: t0))
    }
}

@Suite struct ReleaseMarkerTests {
    @Test(arguments: [
        ("Fixes.\n\n<!-- hook:mailbox-protocol=3 -->\n", 3),
        ("<!--hook:mailbox-protocol=12-->", 12),
        ("<!--  hook:mailbox-protocol = 2  -->", 2),
        ("a <!-- hook:mailbox-protocol=2 --> b <!-- hook:mailbox-protocol=3 -->", 2),
    ])
    func readsTheMarker(_ body: String, _ level: Int) {
        #expect(ReleaseMarker.mailboxLevel(in: body) == level)
    }

    @Test(arguments: ["", "No marker here", "hook:mailbox-protocol=3", "<!-- hook:mailbox-protocol=x -->",
                      "<!-- hook:mailbox-protocol=0 -->", "<!-- hook:mailbox-protocol=-1 -->",
                      "<!-- relay:mailbox-protocol=3 -->"])
    func ignoresAnythingElse(_ body: String) {
        #expect(ReleaseMarker.mailboxLevel(in: body) == nil)
    }

    @Test func latestReleaseCarriesTheMarker() throws {
        let reply = #"{"tag_name":"v0.9.1","html_url":"https://github.com/xooxoxxo/hook/releases/tag/v0.9.1","#
            + #""draft":false,"prerelease":false,"body":"Notes\n<!-- hook:mailbox-protocol=3 -->"}"#
        #expect(try #require(LatestRelease.parse(Data(reply.utf8))).mailboxLevel == 3)
        let none = #"{"tag_name":"v0.9.1","html_url":"https://github.com/xooxoxxo/hook/releases/tag/v0.9.1"}"#
        #expect(try #require(LatestRelease.parse(Data(none.utf8))).mailboxLevel == nil)
    }
}

@Suite struct UpdatePreflightTests {
    @Test func aMailboxBehindTheReleaseStops() {
        #expect(UpdatePreflight.decide(required: 3, source: .mailbox, mailboxLevel: 1)
            == .mailboxBehind(required: 3, current: 1))
    }

    @Test func passes() {
        #expect(UpdatePreflight.decide(required: 3, source: .mailbox, mailboxLevel: 3) == .proceed)
        #expect(UpdatePreflight.decide(required: 3, source: .mailbox, mailboxLevel: 4) == .proceed)
        #expect(UpdatePreflight.decide(required: nil, source: .mailbox, mailboxLevel: 1) == .proceed)
        #expect(UpdatePreflight.decide(required: 3, source: .mailbox, mailboxLevel: nil) == .proceed)
    }

    @Test func aFailedCheckSaysSoAndStillAllowsTheUpdate() {
        let decision = UpdatePreflight.decide(required: 3, source: .mailbox, mailboxLevel: nil, checkFailed: true)
        #expect(decision == .mailboxUnchecked(required: 3))
        #expect(UpdatePreflight.firstButtonUpdatesHook(decision))
        let prompt = UpdatePreflight.prompt(version: "0.9.1", decision: decision)
        #expect(prompt.message == "Update Hook to 0.9.1?")
        #expect(prompt.informative.hasPrefix("Hook couldn't check your Pond"))
        #expect(prompt.informative.contains("level 3"))
        #expect(prompt.buttons == ["Update Hook Anyway", "Cancel"])
        // Without a marker, or in This Mac mode, a failed check changes nothing.
        #expect(UpdatePreflight.decide(required: nil, source: .mailbox, mailboxLevel: nil, checkFailed: true) == .proceed)
        #expect(UpdatePreflight.decide(required: 3, source: .local, mailboxLevel: nil, checkFailed: true) == .proceed)
    }

    @Test func theFirstButtonUpdatesHookUnlessTheMailboxIsBehind() {
        #expect(UpdatePreflight.firstButtonUpdatesHook(.proceed))
        #expect(!UpdatePreflight.firstButtonUpdatesHook(.mailboxBehind(required: 3, current: 2)))
    }

    @Test func repeatClicksAreIgnoredUntilTheDialogCloses() {
        var gate = UpdatePreflight.ConfirmGate()
        let first = gate.begin()
        #expect(first)
        #expect(gate.isOpen)
        let second = gate.begin(), third = gate.begin()
        #expect(!second && !third)
        gate.end()
        #expect(!gate.isOpen)
        let afterClose = gate.begin()
        #expect(afterClose)
    }

    @Test func thisMacAlwaysPasses() {
        #expect(UpdatePreflight.decide(required: 9, source: .local, mailboxLevel: 1) == .proceed)
        #expect(UpdatePreflight.decide(required: 9, source: nil, mailboxLevel: nil) == .proceed)
    }

    @Test func theBehindPromptNamesBothLevelsAndOffersTheMailboxFirst() {
        let prompt = UpdatePreflight.prompt(version: "0.9.1", decision: .mailboxBehind(required: 3, current: 2))
        #expect(prompt.message == "Update Hook to 0.9.1?")
        #expect(prompt.informative.hasPrefix("Hook 0.9.1 needs Pond level 3; yours is 2."))
        #expect(prompt.informative.contains("blocking steps won't work"))
        #expect(prompt.buttons == ["Update Pond First", "Update Hook Anyway", "Cancel"])
    }

    @Test func theUsualPromptIsUnchanged() {
        let prompt = UpdatePreflight.prompt(version: "0.9.1", decision: .proceed)
        #expect(prompt.message == "Update Hook to 0.9.1?")
        #expect(prompt.informative == "Hook rebuilds from your checkout and restarts in about 2 minutes.")
        #expect(prompt.buttons == ["Update", "Cancel"])
    }
}

@Suite struct MailboxNoticeTests {
    @Test func olderNamesWhatWontWorkWithTwoButtons() {
        let notice = PanelNotice.mailboxOlder(missing: [.blocking])
        #expect(notice.text == "Your Pond is older than Hook: blocking steps won't work until it is updated.")
        #expect(notice.kind == .error)
        #expect(notice.actionTitle == "Update Pond…")
        #expect(notice.secondaryActionTitle == "How to update")
        #expect(notice.help != nil)
        #expect(notice.showsOnQueue)
    }

    @Test func newerOffersCheckForUpdates() {
        #expect(PanelNotice.mailboxNewer.text.hasPrefix("Hook is older than your Pond"))
        #expect(PanelNotice.mailboxNewer.actionTitle == "Check for Updates")
        #expect(PanelNotice.mailboxNewer.secondaryActionTitle == nil)
        #expect(PanelNotice.mailboxNewer.kind == .info)
    }

    @Test func afterTheUpdate() {
        #expect(PanelNotice.mailboxUpToDate(level: 3).text == "Your Pond is up to date (protocol level 3).")
        #expect(PanelNotice.mailboxUpdateFailed(reason: "Ghostty isn't installed.").kind == .error)
        #expect(PanelNotice.mailboxUpdateFailed(reason: "x").actionTitle == nil)
    }

    @Test func aCommandThatCantRunGetsItsOwnNotice() {
        let notice = PanelNotice.mailboxUpdateCommandInvalid(reason: "it has a line break")
        #expect(notice.text == "The Pond update command in Settings can't be run: it has a line break.")
        #expect(!notice.text.contains("terminal"))
        #expect(notice.kind == .error)
        #expect(notice.actionTitle == nil)
        #expect(notice != .mailboxUpdateFailed(reason: "it has a line break"))
    }

    @Test func theDocsLinkPointsAtTheUpdatingSection() {
        #expect(MailboxProtocol.updateDocsURL.absoluteString
            == "https://github.com/xooxoxxo/hook/blob/main/docs/mailbox-protocol.md#updating-the-mailbox")
    }
}

@Suite struct MailboxUpdateConfigTests {
    @Test func theCommandIsTrimmedAndEmptyMeansNone() throws {
        let config = try RelayConfig.decode(Data(#"{"mailboxUpdateCommand":"  ~/bin/update-mailbox \n"}"#.utf8))
        #expect(config.mailboxUpdateCommand == "~/bin/update-mailbox")
        #expect(try RelayConfig.decode(Data(#"{"mailboxUpdateCommand":"  "}"#.utf8)).mailboxUpdateCommand == nil)
        #expect(try RelayConfig.decode(Data(#"{"mailboxUpdateCommand":5}"#.utf8)).mailboxUpdateCommand == nil)
        #expect(try RelayConfig.decode(Data("{}".utf8)).mailboxUpdateCommand == nil)
    }

    @Test func theMenuOffersUpdateMailboxNextToCheckForUpdatesInMailboxMode() {
        func titles(mailbox: Bool) -> [String] {
            MenuBarMenu.entries(MenuInputs(notSetUp: false, panelVisible: false, shortcut: nil, statusLine: "",
                                           presenceLine: "", presence: .auto, displays: [], pinned: nil,
                                           mailbox: mailbox)).compactMap {
                if case .item(let title, _, _, _, _, _) = $0 { return title }
                return nil
            }
        }
        let withMailbox = titles(mailbox: true)
        let index = try? #require(withMailbox.firstIndex(of: "Check for Updates…"))
        #expect(index.map { withMailbox[$0 + 1] } == "Update Pond…")
        #expect(!titles(mailbox: false).contains("Update Pond…"))
    }
}
