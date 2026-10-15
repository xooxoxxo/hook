import Foundation
import Testing
@testable import RelayCore

private func decode(_ json: String) throws -> RelayConfig {
    try JSONDecoder().decode(RelayConfig.self, from: Data(json.utf8))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "relay-tests-\(UUID().uuidString)")
}

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private let mailboxProblem = ResolvedSource.invalid("mailbox needs an http(s) mailboxURL and a tokenFile")

@Suite struct ConfigDecodingTests {
    @Test func aV1ConfigResolvesToMailbox() throws {
        let config = try decode(#"{"mailboxURL":"http://127.0.0.1:8790","tokenFile":"/tmp/relay-example-token","port":47823,"pollSeconds":15}"#)
        #expect(config.source == nil)
        #expect(config.context == "personal")
        let expected = MailboxSettings(
            url: try #require(URL(string: "http://127.0.0.1:8790")),
            tokenFile: "/tmp/relay-example-token",
            context: "personal")
        #expect(config.resolvedSource() == .mailbox(expected))
    }

    @Test func sourceResolution() throws {
        #expect(try decode(#"{"source":"local"}"#).resolvedSource() == .local)
        #expect(try decode("{}").resolvedSource() == .incomplete)
        #expect(try decode(#"{"source":"cloud"}"#).resolvedSource() == .incomplete)
        #expect(try decode(#"{"source":"local","mailboxURL":"https://example.invalid"}"#).resolvedSource() == .local)
        #expect(try decode(#"{"source":"mailbox"}"#).resolvedSource() == mailboxProblem)
        #expect(try decode(#"{"source":"mailbox","tokenFile":"/t"}"#).resolvedSource() == mailboxProblem)
        #expect(try decode(#"{"mailboxURL":"ftp://example.invalid","tokenFile":"/t"}"#).resolvedSource() == mailboxProblem)
        #expect(try decode(#"{"mailboxURL":"http://","tokenFile":"/t"}"#).resolvedSource() == mailboxProblem)
        #expect(try decode(#"{"mailboxURL":"https://example.invalid","tokenFile":" "}"#).resolvedSource() == mailboxProblem)
        #expect(try decode(#"{"mailboxURL":"https://example.invalid","tokenFile":"\n"}"#).resolvedSource() == mailboxProblem)

        let work = try decode(#"{"source":"mailbox","mailboxURL":"https://example.invalid/","tokenFile":"/t","context":"work"}"#)
        guard case .mailbox(let settings) = work.resolvedSource() else {
            Issue.record("expected a mailbox source")
            return
        }
        #expect(settings.context == "work")
        #expect(settings.tokenFile == "/t")
    }

    @Test func wrongTypesAndOutOfRangeValuesTakeTheirDefaults() throws {
        let config = try decode("""
        {"context":5,"pollSeconds":"10","hotkey":false,"keepDays":400,"showCount":"yes",
         "sidebarEdge":"top","appearance":3,"notify":{"now":"no","sound":true},"repoPath":7,
         "source":"cloud","mailboxURL":42,"tokenFile":[],"port":null}
        """)
        #expect(config == RelayConfig(notify: NotifySettings(sound: true)))
        #expect(try decode(#"{"pollSeconds":0,"keepDays":0,"notify":"loud"}"#) == RelayConfig())
    }

    @Test func validValuesAreKept() throws {
        let config = try decode("""
        {"source":"local","port":47901,"pollSeconds":30,"hotkey":"","keepDays":365,"showCount":false,
         "sidebarEdge":"left","appearance":"dark","repoPath":"/opt/relay","futureKey":true,
         "notify":{"now":false,"today":false,"whenever":true,"sound":true,"slideIn":false}}
        """)
        #expect(config == RelayConfig(
            source: .local, port: 47901, pollSeconds: 30, hotkey: "", keepDays: 365, showCount: false,
            sidebarEdge: .left, appearance: .dark,
            notify: NotifySettings(now: false, today: false, whenever: true, sound: true, slideIn: false),
            repoPath: "/opt/relay"))
    }

    @Test(arguments: ["0", "65536", "-1", #""47823""#, "1.5", "true"])
    func aBadPortThrows(_ port: String) {
        #expect(throws: (any Error).self) {
            try decode(#"{"source":"local","port":\#(port)}"#)
        }
    }

    @Test func theDirectoryFollowsRelayConfig() {
        let environment = ["RELAY_CONFIG": "/tmp/relay-example/config.json"]
        #expect(RelayConfig.path(environment: environment).path == "/tmp/relay-example/config.json")
        #expect(RelayConfig.directory(environment: environment).path == "/tmp/relay-example")
    }
}

@Suite struct ConfigStoreTests {
    @Test func loadTellsMissingUnreadableAndLoadedApart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "config.json")

        #expect(ConfigStore.load(url) == .missing)
        try PrivateFile.write(Data("{".utf8), to: url)
        #expect(ConfigStore.load(url) == .unreadable("not valid JSON"))
        try PrivateFile.write(Data("[]".utf8), to: url)
        #expect(ConfigStore.load(url) == .unreadable("not a JSON object"))
        try PrivateFile.write(Data(#"{"port":0}"#.utf8), to: url)
        #expect(ConfigStore.load(url) == .unreadable("port must be a whole number from 1 to 65535"))
        try PrivateFile.write(Data(#"{"source":"local"}"#.utf8), to: url)
        #expect(ConfigStore.load(url) == .loaded(RelayConfig(source: .local)))
    }

    @Test func mergeLeavesAnExistingCustomParentAlone() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)
        let url = root.appending(path: "relay.json")

        try ConfigStore.merge(set: ["source": "local"], into: url)
        try ConfigStore.merge(set: ["port": 47901], into: url)

        #expect(try mode(root) & 0o777 == 0o755)
        #expect(try mode(url) & 0o777 == 0o600)
    }

    @Test func mergeKeepsUnknownKeys() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "config.json")
        let before = #"{"mailboxURL":"https://example.invalid","tokenFile":"/t","futureKey":{"a":1}}"#
        try PrivateFile.write(Data(before.utf8), to: url)

        let written = try ConfigStore.merge(set: ["source": "local", "port": 47901], remove: ["tokenFile"], into: url)

        #expect(try Data(contentsOf: url) == written)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["source"] as? String == "local")
        #expect(object["port"] as? Int == 47901)
        #expect(object["tokenFile"] == nil)
        #expect(object["mailboxURL"] as? String == "https://example.invalid")
        #expect((object["futureKey"] as? [String: Any])?["a"] as? Int == 1)
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        let futureKey = try #require(text.range(of: "futureKey"))
        let source = try #require(text.range(of: "source"))
        #expect(futureKey.lowerBound < source.lowerBound)   // sorted keys
        #expect(try mode(url) == 0o600)
    }

    @Test(arguments: ["{ \"port\": ", "[1, 2]", ""])
    func mergeRefusesAFileThatIsNotAnObjectAndWritesNothing(_ contents: String) throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "config.json")
        try PrivateFile.write(Data(contents.utf8), to: url)

        #expect(throws: ConfigError.self) {
            try ConfigStore.merge(set: ["source": "local"], into: url)
        }
        #expect(try Data(contentsOf: url) == Data(contents.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["config.json"])
    }

    @Test func mergeCreatesAnAbsentFilePrivately() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "relay/config.json")

        try ConfigStore.merge(set: ["source": "local"], into: url)

        #expect(try mode(url) == 0o600)
        #expect(try mode(url.deletingLastPathComponent()) == 0o700)
        #expect(ConfigStore.load(url) == .loaded(RelayConfig(source: .local)))
    }
}

/// Review Focus 5: a hand-edited config.json that stops parsing while the app runs.
@Suite struct ConfigReloadTests {
    @Test func theLastGoodConfigStaysWhileTheFileIsBroken() {
        let good = RelayConfig(source: .local, port: 47901)

        let broken = ConfigReload.next(lastGood: good, load: .unreadable("not valid JSON"))
        #expect(broken.config == good)
        #expect(broken.note == "config.json has an error: not valid JSON")

        let gone = ConfigReload.next(lastGood: good, load: .missing)
        #expect(gone.config == good)
        #expect(gone.note == "config.json is missing")

        let fixed = RelayConfig(source: .mailbox, mailboxURL: "https://example.invalid", tokenFile: "/t")
        let next = ConfigReload.next(lastGood: broken.config, load: .loaded(fixed))
        #expect(next.config == fixed)
        #expect(next.note == nil)
    }

    @Test func withNothingGoodYetTheConfigStaysNil() {
        let result = ConfigReload.next(lastGood: nil, load: .unreadable("not a JSON object"))
        #expect(result.config == nil)
        #expect(result.note == "config.json has an error: not a JSON object")
    }

    @Test func aBrokenThenFixedFileOnDisk() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "config.json")
        try PrivateFile.write(Data(#"{"source":"local","port":47901}"#.utf8), to: url)
        var current = ConfigReload.next(lastGood: nil, load: ConfigStore.load(url))
        #expect(current.config?.port == 47901)

        try PrivateFile.write(Data(#"{"source":"local","port":"#.utf8), to: url)   // cut off mid-edit
        current = ConfigReload.next(lastGood: current.config, load: ConfigStore.load(url))
        #expect(current.config?.port == 47901)
        #expect(current.note == "config.json has an error: not valid JSON")

        try PrivateFile.write(Data(#"{"source":"local","port":47902}"#.utf8), to: url)
        current = ConfigReload.next(lastGood: current.config, load: ConfigStore.load(url))
        #expect(current.config?.port == 47902)
        #expect(current.note == nil)
    }
}
