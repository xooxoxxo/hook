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

private let everyFeature: [MailboxFeature] = [.answers, .blocking, .optional, .fileLinks, .corrections, .bugs, .messages,
                                              .requirements, .longText, .sharedProgress]
/// The features the Notice can name: the ones this Hook's range needs.
private let everyNeededFeature: [MailboxFeature] = [.answers, .blocking, .optional, .fileLinks, .corrections]

@Suite struct MailboxProtocolTests {
    @Test func featuresAndThePondVersionsThatHaveThem() {
        let v100 = SemVer(major: 1, minor: 0, patch: 0), v110 = SemVer(major: 1, minor: 1, patch: 0)
        #expect(MailboxFeature.answers.minimumPond == v100)
        #expect(MailboxFeature.blocking.minimumPond == v100)
        #expect(MailboxFeature.optional.minimumPond == v100)
        #expect(MailboxFeature.fileLinks.minimumPond == v100)
        #expect(MailboxFeature.corrections.minimumPond == v110)
        #expect(MailboxFeature.corrections.displayName == "step corrections and the owner key")
        let v120 = SemVer(major: 1, minor: 2, patch: 0)
        #expect(MailboxFeature.bugs.minimumPond == v120)
        #expect(MailboxFeature.messages.minimumPond == v120)
        #expect(MailboxFeature.bugs.displayName == "crash reports sent to your Pond")
        #expect(MailboxFeature.messages.displayName == "messages to sessions")
        #expect(MailboxFeature.allCases.sorted() == everyFeature)
    }

    /// Hook still needs only ^1.1.0: the 1.2.0 features are gated one by one.
    @Test func supportsGatesEachFeatureByThePondVersion() {
        #expect(semver("1.2.0").supports(.bugs))
        #expect(semver("1.3.1").supports(.messages))
        #expect(!semver("1.1.0").supports(.bugs))
        #expect(!semver("1.2.0-rc.1").supports(.bugs))
        #expect(semver("1.1.0").supports(.corrections))
        #expect(!PondVersion.legacy(protocol: 4).supports(.corrections))
        #expect(PondCompat.required == "^1.1.0")
    }

    /// Required steps before Done (Pond 1.3.0) are gated too: never in the older-Pond Notice (RD 21).
    @Test func requirementsAreGatedOnPond130() {
        #expect(MailboxFeature.requirements.minimumPond == SemVer(major: 1, minor: 3, patch: 0))
        #expect(MailboxFeature.requirements.gated)
        #expect(MailboxFeature.requirements.displayName == "required steps before Done")
        #expect(semver("1.3.0").supports(.requirements))
        #expect(!semver("1.2.9").supports(.requirements))
        #expect(!semver("1.3.0-rc.1").supports(.requirements))
        for pond in ["1.1.0", "1.2.0", "1.0.0"] {
            #expect(!MailboxProtocol.missingFeatures(pond: semver(pond)).contains(.requirements), "\(pond)")
        }
        #expect(PondCompat.required == "^1.1.0")
    }

    /// 8000-character messages and reports, multi-line reports (Pond 1.4.0).
    @Test func longTextNeeds140() {
        #expect(MailboxFeature.longText.minimumPond == SemVer(major: 1, minor: 4, patch: 0))
        #expect(MailboxFeature.longText.displayName == "long messages and reports")
        #expect(semver("1.4.0").supports(.longText))
        #expect(semver("1.5.2").supports(.longText))
        #expect(!semver("1.3.0").supports(.longText))
        #expect(!semver("1.4.0-rc.1").supports(.longText))
        #expect(!PondVersion.legacy(protocol: 5).supports(.longText))
    }

    @Test func sharedProgressNeeds150WithoutChangingRequiredCompatibility() {
        #expect(MailboxFeature.sharedProgress.minimumPond == SemVer(major: 1, minor: 5, patch: 0))
        #expect(MailboxFeature.sharedProgress.gated)
        #expect(semver("1.5.0").supports(.sharedProgress))
        #expect(!semver("1.4.9").supports(.sharedProgress))
        #expect(!semver("1.5.0-rc.1").supports(.sharedProgress))
        #expect(!PondVersion.legacy(protocol: 5).supports(.sharedProgress))
        #expect(!MailboxProtocol.missingFeatures(pond: semver("1.4.0")).contains(.sharedProgress))
        #expect(PondCompat.required == "^1.1.0")
    }

    @Test func longTextIsGated() {
        #expect(MailboxFeature.longText.gated)
        for pond in ["1.1.0", "1.2.0", "1.3.0", "1.0.0"] {
            #expect(!MailboxProtocol.missingFeatures(pond: semver(pond)).contains(.longText), "\(pond)")
        }
        #expect(PondCompat.required == "^1.1.0")
    }

    @Test func missingFeaturesComparesTheEffectiveVersion() {
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.0.0")) == [.corrections])
        #expect(MailboxProtocol.missingFeatures(pond: .legacy(protocol: 4)) == [.corrections])
        // Crash reports and messages (1.2.0) are gated one by one, never named in the Notice.
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.1.0")) == [])
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.4.2")) == [])
        #expect(MailboxProtocol.missingFeatures(pond: semver("1.1.0-rc.1")) == [.corrections])
        // Below 4 every feature is missing: accepted, as no Pond runs below protocol 4.
        #expect(MailboxProtocol.missingFeatures(pond: .legacy(protocol: 3)) == everyNeededFeature)
        #expect(MailboxProtocol.missingFeatures(pond: .legacy(protocol: 1)) == everyNeededFeature)
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
        #expect(MailboxCompatibility.evaluate(pond: MailboxVersion.legacy.pond) == .pondOlder(missing: everyNeededFeature))
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

private let caret110 = try! SemverRange("^1.1.0")

@Suite struct UpdatePreflightTests {
    @Test func aPondBelowTheRangeStops() {
        #expect(UpdatePreflight.decide(pondRange: caret110, legacyLevel: 5, source: .mailbox, pond: semver("1.0.0"))
            == .pondBehind(required: "^1.1.0", current: semver("1.0.0")))
        #expect(UpdatePreflight.decide(pondRange: try! SemverRange("^1.2.0"), legacyLevel: nil, source: .mailbox,
                                       pond: semver("1.1.0"))
            == .pondBehind(required: "^1.2.0", current: semver("1.1.0")))
    }

    @Test func aMinorPatchOrMajorBumpNeverForcesAPondUpdate() {
        for pond in ["1.1.0", "1.4.0", "1.1.7", "2.0.0"] {
            #expect(UpdatePreflight.decide(pondRange: caret110, legacyLevel: 5, source: .mailbox, pond: semver(pond))
                == .proceed, "\(pond)")
        }
    }

    @Test func onlyTheOldMarkerComparesLevelsAs09Did() {
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: 5, source: .mailbox, pond: .legacy(protocol: 4))
            == .pondBehind(required: "protocol 5", current: .legacy(protocol: 4)))
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: 3, source: .mailbox, pond: .legacy(protocol: 3)) == .proceed)
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: 4, source: .mailbox, pond: semver("1.0.0")) == .proceed)
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: 5, source: .mailbox, pond: semver("1.1.0")) == .proceed)
        // The protocol the Pond sent wins over its version read as a level.
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: 5, source: .mailbox, pond: semver("1.0.0"), pondLevel: 5)
            == .proceed)
    }

    @Test func anUnparsableRangeFallsBackToTheLevel() {
        let body = "Notes\n<!-- hook:pond=garbage -->\n<!-- hook:mailbox-protocol=4 -->"
        #expect(ReleaseMarker.pondRange(in: body) == nil)
        #expect(ReleaseMarker.mailboxLevel(in: body) == 4)
        #expect(UpdatePreflight.decide(pondRange: ReleaseMarker.pondRange(in: body), legacyLevel: ReleaseMarker.mailboxLevel(in: body),
                                       source: .mailbox, pond: .legacy(protocol: 3))
            == .pondBehind(required: "protocol 4", current: .legacy(protocol: 3)))
    }

    @Test func passesWithoutMarkersOrAReading() {
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: nil, source: .mailbox, pond: semver("1.0.0")) == .proceed)
        #expect(UpdatePreflight.decide(pondRange: caret110, legacyLevel: 5, source: .mailbox, pond: nil) == .proceed)
    }

    @Test func aFailedCheckSaysSoAndStillAllowsTheUpdate() {
        let decision = UpdatePreflight.decide(pondRange: caret110, legacyLevel: 5, source: .mailbox, pond: nil,
                                              checkFailed: true)
        #expect(decision == .pondUnchecked(required: "^1.1.0"))
        #expect(UpdatePreflight.firstButtonUpdatesHook(decision))
        let prompt = UpdatePreflight.prompt(version: "0.11.0", decision: decision)
        #expect(prompt.message == "Update Hook to 0.11.0?")
        #expect(prompt.informative.hasPrefix("Hook couldn't check your Pond"))
        #expect(prompt.informative.contains("^1.1.0"))
        #expect(prompt.buttons == ["Update Hook Anyway", "Cancel"])
        // Without a marker, or in This Mac mode, a failed check changes nothing.
        #expect(UpdatePreflight.decide(pondRange: nil, legacyLevel: nil, source: .mailbox, pond: nil, checkFailed: true)
            == .proceed)
        #expect(UpdatePreflight.decide(pondRange: caret110, legacyLevel: 5, source: .local, pond: nil, checkFailed: true)
            == .proceed)
    }

    @Test func theFirstButtonUpdatesHookUnlessThePondIsBehind() {
        #expect(UpdatePreflight.firstButtonUpdatesHook(.proceed))
        #expect(!UpdatePreflight.firstButtonUpdatesHook(.pondBehind(required: "^1.1.0", current: semver("1.0.0"))))
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
        #expect(UpdatePreflight.decide(pondRange: caret110, legacyLevel: 9, source: .local, pond: semver("0.1.0")) == .proceed)
        #expect(UpdatePreflight.decide(pondRange: caret110, legacyLevel: 9, source: nil, pond: nil) == .proceed)
    }

    @Test func theBehindPromptNamesBothVersionsAndOffersThePondFirst() {
        let prompt = UpdatePreflight.prompt(version: "0.11.0",
                                            decision: .pondBehind(required: "^1.2.0", current: semver("1.1.0")))
        #expect(prompt.message == "Update Hook to 0.11.0?")
        #expect(prompt.informative.hasPrefix("Hook 0.11.0 needs Pond ^1.2.0. Your Pond is 1.1.0."))
        #expect(prompt.buttons == ["Update Pond First", "Update Hook Anyway", "Cancel"])
        let legacy = UpdatePreflight.prompt(version: "0.11.0",
                                            decision: .pondBehind(required: "protocol 5", current: .legacy(protocol: 4)))
        #expect(legacy.informative.hasPrefix("Hook 0.11.0 needs Pond protocol 5. Your Pond is protocol 4."))
    }

    @Test func theUsualPromptIsUnchanged() {
        let prompt = UpdatePreflight.prompt(version: "0.9.1", decision: .proceed)
        #expect(prompt.message == "Update Hook to 0.9.1?")
        #expect(prompt.informative == "Hook rebuilds from your checkout and restarts in about 2 minutes.")
        #expect(prompt.buttons == ["Update", "Cancel"])
    }
}

@Suite struct PondRangeMarkerTests {
    @Test func readsTheFirstRangeMarker() {
        #expect(ReleaseMarker.pondRange(in: "x <!-- hook:pond=^1.1.0 --> <!-- hook:pond=^2.0.0 -->")?.description == "^1.1.0")
        #expect(ReleaseMarker.pondRange(in: "<!--hook:pond= >=1.1.0 <2.0.0 -->")?.description == ">=1.1.0 <2.0.0")
        #expect(ReleaseMarker.pondRange(in: "no marker") == nil)
    }

    @Test func latestReleaseCarriesTheRange() throws {
        let reply = #"{"tag_name":"v0.11.0","html_url":"https://github.com/xooxoxxo/hook/releases/tag/v0.11.0","#
            + #""body":"Notes\n<!-- hook:pond=^1.1.0 -->\n<!-- hook:mailbox-protocol=5 -->"}"#
        let release = try #require(LatestRelease.parse(Data(reply.utf8)))
        #expect(release.pondRange == "^1.1.0")
        #expect(release.mailboxLevel == 5)
    }

    /// The next release's CHANGELOG section carries both markers, its range equal to what
    /// this Hook requires (the first section is the one being released).
    @Test func theNewestChangelogSectionCarriesBothMarkers() throws {
        let changelog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let sections = text.components(separatedBy: "\n## [")
        #expect(sections.count > 2)
        let newest = sections[1]
        #expect(ReleaseMarker.pondRange(in: newest)?.description == PondCompat.required)
        #expect(ReleaseMarker.mailboxLevel(in: newest) == 5)
    }
}

@Suite struct MailboxNoticeTests {
    @Test func olderNamesBothVersionsWithTwoButtons() {
        let notice = PanelNotice.pondOlder(current: "1.0.0", required: "^1.1.0", missing: [.corrections])
        #expect(notice.text == "Your Pond (1.0.0) is older than this Hook needs (^1.1.0).")
        #expect(notice.kind == .error)
        #expect(notice.actionTitle == "Update Pond…")
        #expect(notice.secondaryActionTitle == "How to update")
        #expect(notice.help?.contains("step corrections and the owner key won't work") == true)
        #expect(notice.showsOnQueue)
        #expect(PanelNotice.pondOlder(current: "protocol 4", required: "^1.1.0", missing: []).text
            == "Your Pond (protocol 4) is older than this Hook needs (^1.1.0).")
    }

    @Test func newerOffersCheckForUpdates() {
        let notice = PanelNotice.hookOlder(pond: "2.0.0")
        #expect(notice.text.hasPrefix("Hook is older than your Pond (2.0.0)."))
        #expect(notice.actionTitle == "Check for Updates")
        #expect(notice.secondaryActionTitle == nil)
        #expect(notice.kind == .info)
    }

    @Test func theCompatibilityByVersion() {
        #expect(MailboxCompatibility.evaluate(pond: semver("1.0.0")) == .pondOlder(missing: [.corrections]))
        #expect(MailboxCompatibility.evaluate(pond: semver("2.0.0")) == .hookOlder)
        #expect(MailboxCompatibility.evaluate(pond: semver("1.2.0")) == .ok)
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
        let index = withMailbox.firstIndex(of: "Check for Updates…")
        #expect(index.map { withMailbox[$0 + 1] } == "Update Pond…")
        #expect(!titles(mailbox: false).contains("Update Pond…"))
    }
}
