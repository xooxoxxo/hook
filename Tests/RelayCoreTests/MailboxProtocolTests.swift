import Foundation
import Testing
@testable import RelayCore

private let key = "mailbox:mailbox.example:8790#personal"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func check(level: Int?, key: String = key, at date: Date = t0) -> MailboxCheck {
    MailboxCheck(sourceKey: key, result: level.map { .version(MailboxVersion(version: "2026.10.27.1", level: $0)) }
        ?? .failed(reason: "the mailbox didn't answer"), checkedAt: date)
}

private func check(pond version: String, level: Int? = 5) -> MailboxCheck {
    MailboxCheck(sourceKey: key, result: .version(MailboxVersion(service: "pond", version: version, level: level)),
                 checkedAt: t0)
}

private func semver(_ text: String) -> PondVersion { .semver(SemVer(strict: text)!) }

private let everyFeature: [MailboxFeature] = [.answers, .blocking, .optional, .fileLinks, .corrections]

@Suite struct MailboxProtocolTests {
    @Test func featuresAndThePondVersionsThatHaveThem() {
        let v100 = SemVer(major: 1, minor: 0, patch: 0), v110 = SemVer(major: 1, minor: 1, patch: 0)
        #expect(MailboxFeature.answers.minimumPond == v100)
        #expect(MailboxFeature.blocking.minimumPond == v100)
        #expect(MailboxFeature.optional.minimumPond == v100)
        #expect(MailboxFeature.fileLinks.minimumPond == v100)
        #expect(MailboxFeature.corrections.minimumPond == v110)
        #expect(MailboxFeature.corrections.displayName == "step corrections and the owner key")
        #expect(MailboxFeature.allCases.sorted() == everyFeature)
    }

    @Test func missingFeaturesComparesTheEffectiveVersion() {
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.0.0")) == [.corrections])
        #expect(MailboxProtocol.missingFeatures(pond: .legacy(protocol: 4)) == [.corrections])
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.1.0")) == [])
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.4.2")) == [])
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.1.0-rc.1")) == [.corrections])
        // Below 4 every feature is missing: accepted, as no Pond runs below protocol 4.
        #expect(MailboxProtocol.missingFeatures(pond: .legacy(protocol: 3)) == everyFeature)
        #expect(MailboxProtocol.missingFeatures(pond: .legacy(protocol: 1)) == everyFeature)
    }

    @Test func featureListReadsAsASentence() {
        #expect(MailboxProtocol.featureList([.blocking]) == "blocking steps")
        #expect(MailboxProtocol.featureList([.blocking, .answers]) == "per-step answers and blocking steps")
        #expect(MailboxProtocol.featureList([.optional, .answers, .blocking])
            == "per-step answers, blocking steps and optional steps")
        #expect(MailboxProtocol.featureList([.fileLinks, .optional]) == "optional steps and file links")
        #expect(MailboxProtocol.featureList([.fileLinks, .blocking, .optional, .answers])
            == "per-step answers, blocking steps, optional steps and file links")
        #expect(MailboxProtocol.featureList([.corrections]) == "step corrections and the owner key")
        #expect(MailboxProtocol.featureList([]) == "")
    }

    @Test(arguments: [("1.0.0", MailboxCompatibility.pondOlder(missing: [.corrections])),
                      ("1.1.0", .ok), ("1.7.0", .ok), ("1.2.0-rc.1", .ok), ("2.0.0", .hookOlder),
                      ("1.1.0-rc.1", .pondOlder(missing: [.corrections]))])
    func compatibility(_ version: String, _ expected: MailboxCompatibility) {
        #expect(MailboxCompatibility.evaluate(pond: semver(version)) == expected)
    }

    @Test func oldPondsAreReadByTheirProtocol() throws {
        let dated = try JSONDecoder().decode(MailboxVersion.self,
                                             from: Data(#"{"version":"2026.10.27.1","protocol":4}"#.utf8))
        #expect(dated.pond == .legacy(protocol: 4))
        #expect(MailboxCompatibility.evaluate(pond: dated.pond) == .pondOlder(missing: [.corrections]))
        #expect(MailboxVersion.legacy.pond == .legacy(protocol: 1))
        #expect(MailboxCompatibility.evaluate(pond: MailboxVersion.legacy.pond) == .pondOlder(missing: everyFeature))
    }

    @Test func anotherRangeCanBeAsked() throws {
        let range = try SemverRange("^1.2.0")
        #expect(MailboxCompatibility.evaluate(pond: semver("1.1.0"), required: range) == .pondOlder(missing: []))
        #expect(MailboxCompatibility.evaluate(pond: semver("1.3.0"), required: range) == .ok)
    }

    @Test func versionDecodesTheProtocolKey() throws {
        let data = Data(#"{"service":"pond","version":"1.1.0","protocol":5,"extra":true}"#.utf8)
        let version = try JSONDecoder().decode(MailboxVersion.self, from: data)
        #expect(version == MailboxVersion(service: "pond", version: "1.1.0", level: 5))
        #expect(version.pond == semver("1.1.0"))
        let bare = try JSONDecoder().decode(MailboxVersion.self, from: Data(#"{"protocol":1,"version":7}"#.utf8))
        #expect(bare == MailboxVersion(level: 1))
        let noProtocol = try JSONDecoder().decode(MailboxVersion.self, from: Data(#"{"version":"2.0.0"}"#.utf8))
        #expect(noProtocol.level == nil && noProtocol.pond == semver("2.0.0"))
    }

    /// The same `pond` vectors relay_semver reads, through the `/version` decode.
    @Test func everyPondVectorDecodesThroughVersion() throws {
        let url = try #require(Bundle.module.url(
            forResource: "semver-vectors", withExtension: "json", subdirectory: "Fixtures"))
        guard case .array(let cases)? = try JSONValue.parse(Data(contentsOf: url))["cases"] else {
            Issue.record("no cases")
            return
        }
        let ponds = cases.filter { $0["kind"]?.stringValue == "pond" }
        #expect(ponds.count >= 10)
        for item in ponds {
            let info = try #require(item["info"])
            let version = info == .null ? MailboxVersion.legacy : try JSONDecoder().decode(MailboxVersion.self, from: info.data())
            #expect(version.pond.effective.description == item["effective"]?.stringValue, "\(info)")
            if case .int(let level)? = item["legacy"] {
                #expect(version.pond == .legacy(protocol: level), "\(info)")
            }
        }
    }

    @Test func versionLine() {
        #expect(MailboxVersionLine.line(check(pond: "1.1.0"), checking: false)
            == MailboxVersionLine(text: "Pond 1.1.0 ✓ (needs ^1.1.0)", state: .ok))
        #expect(MailboxVersionLine.line(check(pond: "1.7.0"), checking: false).state == .ok)
        let behind = MailboxVersionLine.line(check(pond: "1.0.0", level: 4), checking: false)
        #expect(behind == MailboxVersionLine(text: "Pond 1.0.0 (needs ^1.1.0)", state: .needsUpdate))
        #expect(behind.badge == "Needs an update")
        let newer = MailboxVersionLine.line(check(pond: "2.0.0", level: nil), checking: false)
        #expect(newer == MailboxVersionLine(text: "Pond 2.0.0 (this Hook needs ^1.1.0)", state: .hookOlder))
        #expect(newer.badge == "Newer than Hook")
        #expect(MailboxVersionLine.line(check(pond: "2026.10.27.1", level: 4), checking: false)
            == MailboxVersionLine(text: "Pond (protocol 4) (needs ^1.1.0)", state: .needsUpdate))
        let legacy = MailboxCheck(sourceKey: key, result: .version(.legacy), checkedAt: t0)
        #expect(MailboxVersionLine.line(legacy, checking: false).text == "Pond (protocol 1) (needs ^1.1.0)")
        #expect(MailboxVersionLine.line(check(level: nil), checking: false)
            == MailboxVersionLine(text: "Couldn't check: the mailbox didn't answer", state: .failed))
        #expect(MailboxVersionLine.line(check(pond: "1.1.0"), checking: true).state == .checking)
        #expect(MailboxVersionLine.line(nil, checking: false).text == "Not checked yet")
    }

    @Test func versionLineRevealsHiddenCharactersInTheServersVersion() {
        let odd = MailboxCheck(sourceKey: key, result: .version(MailboxVersion(version: "1.0\u{202E}x", level: 3)),
                               checkedAt: t0)
        #expect(!MailboxVersionLine.line(odd, checking: false).text.contains("\u{202E}"))
    }

    @Test func aCheckCarriesThePondAndTheLevelTheUpdaterReads() {
        #expect(check(pond: "1.1.0").pond == semver("1.1.0"))
        #expect(check(pond: "1.1.0").updaterLevel == 5)
        #expect(check(pond: "1.1.0", level: nil).updaterLevel == 4)
        #expect(check(level: 3).pond == .legacy(protocol: 3))
        #expect(check(level: 3).updaterLevel == 3)
        #expect(check(level: nil).pond == nil)
        #expect(check(level: nil).updaterLevel == nil)
        #expect(check(level: nil).compatibility == nil)
        #expect(check(pond: "1.0.0").compatibility == .pondOlder(missing: [.corrections]))
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
        #expect(prompt.informative.contains("blocking steps"))
        #expect(prompt.buttons == ["Update Pond First", "Update Hook Anyway", "Cancel"])
    }

    @Test func theBehindPromptNamesWhatThisHookUsesAndThePondLacks() {
        let prompt = UpdatePreflight.prompt(version: "0.10.0", decision: .mailboxBehind(required: 5, current: 4))
        #expect(prompt.informative.contains("step corrections and the owner key won't work"))
        #expect(!prompt.informative.contains("blocking steps"))
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
        #expect(PanelNotice.mailboxUpToDate(pond: "1.1.0").text == "Your Pond is up to date (1.1.0).")
        #expect(PanelNotice.mailboxUpToDate(pond: "protocol 4").text == "Your Pond is up to date (protocol 4).")
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
