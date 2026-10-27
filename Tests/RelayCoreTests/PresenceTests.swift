import Foundation
import Testing
@testable import RelayCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "relay-tests-\(UUID().uuidString)")
}

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func decode(_ json: String) throws -> RelayConfig {
    try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))
}

@Suite struct RemoteSessionTests {
    @Test func screensharingdMeansConnected() {
        #expect(RemoteSession.isConnected(holders: ["powerd", "screensharingd", "WindowServer"]))
        #expect(RemoteSession.isConnected(holders: ["screensharingd"]))
    }

    @Test func noHoldersOrOtherDaemonsOnlyMeanNotConnected() {
        #expect(!RemoteSession.isConnected(holders: []))
        #expect(!RemoteSession.isConnected(holders: ["powerd", "WindowServer", "caffeinate", "coreaudiod"]))
    }

    @Test func namesMustMatchExactly() {
        #expect(!RemoteSession.isConnected(holders: ["ScreenSharingd", "screensharingd-helper", "screensharing"]))
    }
}

@Suite struct PresenceLogicTests {
    private let everything = PresenceSignals(screenLocked: true, screensAsleep: true, sessionActive: false, remoteSession: true, idleSeconds: 99_999)

    @Test func homeAndAwayAreSetByYouWhateverTheSignals() {
        for signals in [PresenceSignals(), everything] {
            let home = PresenceLogic.evaluate(mode: .home, signals: signals, awayAfterMinutes: 10)
            #expect(home.state == .home)
            #expect(home.reason == "set by you")
            let away = PresenceLogic.evaluate(mode: .away, signals: signals, awayAfterMinutes: 10)
            #expect(away.state == .away)
            #expect(away.reason == "set by you")
        }
    }

    @Test(arguments: [
        (PresenceSignals(), PresenceState.home, "active"),
        (PresenceSignals(screenLocked: true), .away, "screen locked"),
        (PresenceSignals(screensAsleep: true), .away, "displays asleep"),
        (PresenceSignals(sessionActive: false), .away, "switched user"),
        (PresenceSignals(remoteSession: true), .away, "screen sharing"),
        (PresenceSignals(idleSeconds: 600), .away, "idle 10 min"),
        (PresenceSignals(idleSeconds: 599.9), .home, "active"),
    ])
    func automaticRows(signals: PresenceSignals, state: PresenceState, reason: String) {
        let result = PresenceLogic.evaluate(mode: .auto, signals: signals, awayAfterMinutes: 10)
        #expect(result.state == state)
        #expect(result.reason == reason)
    }

    @Test func automaticReportsTheFirstSignalThatHolds() {
        func reason(_ signals: PresenceSignals) -> String {
            PresenceLogic.evaluate(mode: .auto, signals: signals, awayAfterMinutes: 5).reason
        }
        #expect(reason(everything) == "screen locked")
        #expect(reason(PresenceSignals(screensAsleep: true, sessionActive: false, remoteSession: true, idleSeconds: 99_999)) == "displays asleep")
        #expect(reason(PresenceSignals(sessionActive: false, remoteSession: true, idleSeconds: 99_999)) == "switched user")
        #expect(reason(PresenceSignals(remoteSession: true, idleSeconds: 99_999)) == "screen sharing")
        #expect(reason(PresenceSignals(idleSeconds: 99_999)) == "idle 5 min")
    }

    @Test func screenSharingIsAwayEvenWhileRemoteInputKeepsIdleAtZero() {
        let result = PresenceLogic.evaluate(mode: .auto, signals: PresenceSignals(remoteSession: true, idleSeconds: 0), awayAfterMinutes: 60)
        #expect(result.state == .away)
        #expect(result.reason == "screen sharing")
    }

    @Test func screenSharingDoesNotOverrideHomeOrAway() {
        let signals = PresenceSignals(remoteSession: true)
        #expect(PresenceLogic.evaluate(mode: .home, signals: signals, awayAfterMinutes: 10) == (.home, "set by you"))
        #expect(PresenceLogic.evaluate(mode: .away, signals: signals, awayAfterMinutes: 10) == (.away, "set by you"))
    }

    @Test(arguments: [5, 10, 15, 30, 60])
    func idleThresholdFollowsTheMinutes(minutes: Int) {
        let limit = Double(minutes) * 60
        #expect(PresenceLogic.evaluate(mode: .auto, signals: PresenceSignals(idleSeconds: limit - 1), awayAfterMinutes: minutes).state == .home)
        let away = PresenceLogic.evaluate(mode: .auto, signals: PresenceSignals(idleSeconds: limit), awayAfterMinutes: minutes)
        #expect(away.state == .away)
        #expect(away.reason == "idle \(minutes) min")
    }

    @Test func returnSummary() {
        #expect(PresenceLogic.returnSummary(count: 0) == nil)
        #expect(PresenceLogic.returnSummary(count: -1) == nil)
        #expect(PresenceLogic.returnSummary(count: 1) == "1 ask arrived while you were away")
        #expect(PresenceLogic.returnSummary(count: 2) == "2 asks arrived while you were away")
        #expect(PresenceLogic.returnSummary(count: 12) == "12 asks arrived while you were away")
    }

    @Test func statusLine() {
        #expect(PresenceLogic.statusLine(state: .away, reason: "screen locked", since: "10:22") == "Away · screen locked · since 10:22")
        #expect(PresenceLogic.statusLine(state: .home, reason: "active", since: "10:22") == "Home · active")
        #expect(PresenceLogic.statusLine(state: .home, reason: "set by you", since: "09:00") == "Home · set by you")
    }
}

@Suite struct AwayTallyTests {
    @Test func homeLetsAsksThroughAndCountsNothing() {
        var tally = AwayTally()
        let through = tally.arrived(3)
        let summary = tally.changed(to: .home)
        #expect(through)
        #expect(tally.count == 0)
        #expect(summary == nil)
    }

    @Test func awayCountsAndReturnSummarisesOnce() {
        var tally = AwayTally()
        let leaving = tally.changed(to: .away)
        let first = tally.arrived(2)
        let second = tally.arrived(1)
        #expect(leaving == nil)
        #expect(!first && !second)
        #expect(tally.count == 3)
        let newReason = tally.changed(to: .away)   // a new reason, still away
        #expect(newReason == nil)
        #expect(tally.count == 3)
        let back = tally.changed(to: .home)
        #expect(back == "3 asks arrived while you were away")
        #expect(tally.count == 0)
        let again = tally.changed(to: .home)
        let later = tally.arrived(1)
        #expect(again == nil)
        #expect(later)
    }

    @Test func aQuietAbsenceEndsWithoutASummary() {
        var tally = AwayTally(state: .away)
        let through = tally.arrived(0)
        let back = tally.changed(to: .home)
        #expect(!through)
        #expect(back == nil)
        #expect(tally.state == .home)
    }
}

@Suite struct AwayFlagTests {
    private let since = Date(timeIntervalSince1970: 1_792_145_000)   // 2026-10-16T10:03:20Z

    @Test func setWritesTwoLinesInAPrivateDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = AwayFlag(directory: root.appending(path: "state/relay"))
        #expect(!flag.isSet)

        try flag.set(reason: "screen locked", since: since).get()

        #expect(flag.isSet)
        #expect(try String(contentsOf: flag.file, encoding: .utf8) == "since=2026-10-16T10:03:20Z\nreason=screen locked\n")
        #expect(try mode(flag.directory) == 0o700)
        #expect(try mode(flag.file) == 0o600)
        #expect(flag.file.lastPathComponent == "away")
    }

    @Test func setAndClearAreIdempotent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = AwayFlag(directory: root)

        try flag.clear().get()   // nothing there yet
        try flag.set(reason: "idle 10 min", since: since).get()
        try flag.set(reason: "screen locked", since: since).get()
        #expect(try String(contentsOf: flag.file, encoding: .utf8).hasSuffix("reason=screen locked\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["away"])

        try flag.clear().get()
        #expect(!flag.isSet)
        try flag.clear().get()
        #expect(!FileManager.default.fileExists(atPath: flag.file.path))
    }

    @Test func aStaleDirectoryIsTightened() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)

        try AwayFlag(directory: root).set(reason: "set by you", since: since).get()

        #expect(try mode(root) == 0o700)
    }

    @Test func aSymlinkIsNeverFollowed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = AwayFlag(directory: root.appending(path: "relay"))
        try FileManager.default.createDirectory(at: flag.directory, withIntermediateDirectories: true)
        let target = root.appending(path: "target.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: flag.file, withDestinationURL: target)

        #expect(throws: (any Error).self) { try flag.set(reason: "screen locked", since: since).get() }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(!flag.isSet)

        try flag.clear().get()   // removes the link, not its target
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: flag.file.path)) == nil)
    }

    @Test func aReasonStaysOnOneLine() {
        #expect(AwayFlag.contents(reason: "a\nb\rc", since: since) == "since=2026-10-16T10:03:20Z\nreason=a b c\n")
    }

    @Test func standardLivesInLocalState() {
        #expect(AwayFlag.standard.file.path.hasSuffix("/.local/state/relay/away"))
    }
}

@Suite struct PresenceConfigTests {
    @Test func missingKeysTakeTheirDefaults() throws {
        let config = try decode("{}")
        #expect(config.presence == .auto)
        #expect(config.awayAfterMinutes == 10)
    }

    @Test(arguments: ["auto", "home", "away"])
    func validPresenceIsKept(_ raw: String) throws {
        #expect(try decode(#"{"presence":"\#(raw)"}"#).presence == PresenceMode(rawValue: raw))
    }

    @Test(arguments: [#""Away""#, #""present""#, "1", "true", "null", "[]"])
    func invalidPresenceIsAuto(_ raw: String) throws {
        #expect(try decode(#"{"presence":\#(raw)}"#).presence == .auto)
    }

    @Test(arguments: [5, 10, 15, 30, 60])
    func validMinutesAreKept(_ minutes: Int) throws {
        #expect(try decode(#"{"awayAfterMinutes":\#(minutes)}"#).awayAfterMinutes == minutes)
    }

    @Test(arguments: ["0", "1", "7", "45", "120", "-5", "10.5", #""10""#, "null", "false"])
    func invalidMinutesAreTen(_ raw: String) throws {
        #expect(try decode(#"{"awayAfterMinutes":\#(raw)}"#).awayAfterMinutes == 10)
    }

    @Test func mergeSaveKeepsUnrelatedKeys() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "config.json")
        try PrivateFile.write(Data(#"{"source":"local","hotkey":"","futureKey":[1,2]}"#.utf8), to: url)

        try ConfigStore.merge(set: ["presence": "away"], into: url)
        try ConfigStore.merge(set: ["awayAfterMinutes": 30], into: url)

        guard case .loaded(let config) = ConfigStore.load(url) else {
            Issue.record("expected a loaded config")
            return
        }
        #expect(config.presence == .away)
        #expect(config.awayAfterMinutes == 30)
        #expect(config.source == .local)
        #expect(config.hotkey == "")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["futureKey"] as? [Int] == [1, 2])
    }
}

@Suite struct AwayMenuBarTests {
    @Test func awayDimsOnlyTheSymbol() {
        let state = MenuBarState(count: 2, reachable: true, unseen: true, away: true)
        #expect(state.symbolDimmed)
        #expect(!state.dimmed)
        #expect(state.badge == .dot)
        #expect(state.accessibilityLabel == "Hook, 2 waiting, away")
        #expect(state.tooltip == "Hook · away · 2 waiting")
    }

    @Test func offlineWinsTheTooltip() {
        let state = MenuBarState(count: 0, reachable: false, offlineReason: "timed out", away: true)
        #expect(state.symbolDimmed)
        #expect(state.tooltip == "Hook · offline: timed out")
        #expect(state.accessibilityLabel == "Hook, 0 waiting, offline, away")
    }

    @Test func homeIsUnchanged() {
        #expect(!MenuBarState(count: 1).symbolDimmed)
        #expect(MenuBarState(count: 1).tooltip == "Hook · 1 waiting")
    }
}
