import Foundation
import Testing
@testable import RelayCore

func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "relay.tests.tickstore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

private func tree(_ steps: [Step], verify: Step? = nil) -> [DetailModel.Node] {
    DetailModel.nodes(steps: steps, verify: verify)
}

private let original = tree([
    Step(action: "Open Slack"),
    Step(action: "Create the app", substeps: [Step(action: "Click New"), Step(action: "Name it")]),
    Step(action: "Invite the bot"),
], verify: Step(action: "Check", code: "ls"))

@Suite struct TickStoreTests {
    @Test func keyFormat() {
        #expect(TickStore.key(sourceKey: "local", id: "a") == "relay.ticks.v2.local.a")
        #expect(TickStore.key(sourceKey: "mailbox:mail.example.com#work", id: "a") == "relay.ticks.v2.mailbox:mail.example.com#work.a")
    }

    @Test func saveStoresLeavesWithFingerprints() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["1", "2", "2.2", "verify", "gone"], nodes: original)
            let stored = d.dictionary(forKey: "relay.ticks.v2.local.a") as? [String: String]
            #expect(stored == ["1": original[0].fingerprint, "2.2": original[1].children[1].fingerprint,
                               "verify": original[3].fingerprint])
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["2"], nodes: original)
            #expect(d.object(forKey: "relay.ticks.v2.local.a") == nil)
        }
    }

    @Test func matchByPathAndFingerprint() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["1", "2.1"], nodes: original)
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: original) == ["1", "2.1"])
        }
    }

    @Test func aMovedStepKeepsItsTick() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["3"], nodes: original)
            // Re-posted with a new first step: "Invite the bot" is now step 4.
            let reposted = tree([
                Step(action: "Read the brief"), Step(action: "Open Slack"),
                Step(action: "Create the app", substeps: [Step(action: "Click New"), Step(action: "Name it")]),
                Step(action: "Invite the bot"),
            ], verify: Step(action: "Check", code: "ls"))
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: reposted) == ["4"])
            #expect((d.dictionary(forKey: "relay.ticks.v2.local.a") as? [String: String])?.keys.sorted() == ["4"])
        }
    }

    @Test func aChangedStepDropsItsTick() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["1", "3"], nodes: original)
            let edited = tree([Step(action: "Open Slack"), Step(action: "Create the app"), Step(action: "Invite the bots")])
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: edited) == ["1"])
            #expect((d.dictionary(forKey: "relay.ticks.v2.local.a") as? [String: String])?.keys.sorted() == ["1"])
        }
    }

    @Test func repeatedIdenticalStepsAreSettledByPath() throws {
        let twice = tree([Step(action: "Restart"), Step(action: "Wait"), Step(action: "Restart")])
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["3"], nodes: twice)
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: twice) == ["3"])
            // With the path gone, two leaves share the fingerprint: ambiguous, so dropped.
            let three = tree([Step(action: "Restart"), Step(action: "Restart")])
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: three) == [])
        }
    }

    @Test func parentsAreNeverStoredOrLoaded() throws {
        try withDefaults { d in
            d.set(["2": original[1].fingerprint], forKey: "relay.ticks.v2.local.a")
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: original) == [])
        }
    }

    @Test func pruneKeepsOtherSourcesAndKeptIDs() throws {
        try withDefaults { d in
            for (source, id) in [("local", "a"), ("local", "b"), ("mailbox:m.example#w", "a"), ("mailbox:m.example#w.x", "c")] {
                TickStore.save(d, sourceKey: source, id: id, ticks: ["1"], nodes: original)
            }
            d.set([0], forKey: "relay.ticks.local.b")
            TickStore.prune(d, sourceKey: "local", keep: ["a"])
            #expect(d.object(forKey: "relay.ticks.v2.local.a") != nil)
            #expect(d.object(forKey: "relay.ticks.v2.local.b") == nil)
            #expect(d.object(forKey: "relay.ticks.local.b") != nil)
            TickStore.prune(d, sourceKey: "mailbox:m.example#w", keep: [])
            #expect(d.object(forKey: "relay.ticks.v2.mailbox:m.example#w.a") == nil)
            #expect(d.object(forKey: "relay.ticks.v2.mailbox:m.example#w.x.c") != nil)
        }
    }
}

@Suite struct TickMigrationTests {
    private let plain = DetailModel.nodes(steps: [Step(action: "One"), Step(action: "Two"), Step(action: "Three")],
                                          verify: Step(action: "Check"))

    @Test func legacyKeyFormat() {
        #expect(TickStore.legacyKey(sourceKey: "local", id: "a") == "relay.ticks.local.a")
    }

    @Test func plainIndicesBecomePaths() throws {
        try withDefaults { d in
            d.set([0, 2], forKey: "relay.ticks.local.a")
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: plain) == ["1", "3"])
            #expect(d.object(forKey: "relay.ticks.local.a") == nil)
            #expect((d.dictionary(forKey: "relay.ticks.v2.local.a") as? [String: String])?.keys.sorted() == ["1", "3"])
        }
    }

    @Test func aStepThatGainedSubstepsTicksThemAll() throws {
        let grown = DetailModel.nodes(steps: [Step(action: "One"), Step(action: "Two", substeps: [Step(action: "a"), Step(action: "b")])],
                                      verify: nil)
        try withDefaults { d in
            d.set([1], forKey: "relay.ticks.local.a")
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: grown) == ["2.1", "2.2"])
        }
    }

    @Test func theIndexAfterTheStepsIsVerify() throws {
        try withDefaults { d in
            d.set([3], forKey: "relay.ticks.local.a")
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: plain) == ["verify"])
        }
    }

    @Test func outOfRangeMigratesNothingAndDeletesV1() throws {
        try withDefaults { d in
            d.set([0, 7], forKey: "relay.ticks.local.a")
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: plain) == [])
            #expect(d.object(forKey: "relay.ticks.local.a") == nil)
            #expect(d.object(forKey: "relay.ticks.v2.local.a") == nil)
            let noVerify = DetailModel.nodes(steps: [Step(action: "One")], verify: nil)
            d.set([1], forKey: "relay.ticks.local.b")
            #expect(TickStore.load(d, sourceKey: "local", id: "b", nodes: noVerify) == [])
        }
    }

    @Test func aV2KeyWinsAndV1IsLeftAlone() throws {
        try withDefaults { d in
            TickStore.save(d, sourceKey: "local", id: "a", ticks: ["2"], nodes: plain)
            d.set([0], forKey: "relay.ticks.local.a")
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: plain) == ["2"])
            #expect(d.array(forKey: "relay.ticks.local.a") as? [Int] == [0])
        }
    }

    @Test func noKeysAtAll() throws {
        try withDefaults { d in
            #expect(TickStore.migrateV1(d, sourceKey: "local", id: "a", nodes: plain) == nil)
            #expect(TickStore.load(d, sourceKey: "local", id: "a", nodes: plain) == [])
        }
    }
}
