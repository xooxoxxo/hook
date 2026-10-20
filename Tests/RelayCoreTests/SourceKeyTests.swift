import Foundation
import Testing
@testable import RelayCore

private func mailbox(_ url: String, context: String = "personal") throws -> MailboxSettings {
    MailboxSettings(url: try #require(URL(string: url)), tokenFile: "/tmp/relay-example-token", context: context)
}

@Suite struct SourceKeyTests {
    @Test func constants() {
        #expect(SourceKey.none == "none")
        #expect(SourceKey.local == "local")
        #expect(SourceKey.migratedFlag == "relay.migrated.sourceKey.v2")
    }

    @Test func mailboxKeyVariants() throws {
        #expect(SourceKey.mailbox(try mailbox("https://mail.example.com")) == "mailbox:mail.example.com#personal")
        #expect(SourceKey.mailbox(try mailbox("https://Mail.Example.com/")) == "mailbox:mail.example.com#personal")
        #expect(SourceKey.mailbox(try mailbox("http://mail.example.com:8790", context: "work")) == "mailbox:mail.example.com:8790#work")
        #expect(SourceKey.mailbox(try mailbox("https://mail.example.com/relay/v1/")) == "mailbox:mail.example.com/relay/v1#personal")
        #expect(SourceKey.mailbox(try mailbox("https://mail.example.com:443/x")) == "mailbox:mail.example.com:443/x#personal")
        #expect(SourceKey.mailbox(try mailbox("https://mail.example.com", context: "a"))
            != SourceKey.mailbox(try mailbox("https://mail.example.com", context: "b")))
    }

    @Test func legacyKeyIsTheOldFormat() throws {
        #expect(SourceKey.legacyMailbox(try mailbox("https://Mail.Example.com:8790/relay")) == "mailbox:Mail.Example.com")
    }

    @Test func identityIgnoresNothingButHasNoPoll() throws {
        let a = SourceIdentity(key: "local", mailbox: nil)
        #expect(a == SourceIdentity(key: "local", mailbox: nil))
        #expect(a != SourceIdentity(key: "mailbox:m#p", mailbox: try mailbox("https://m")))
    }

    @Test func migrationCopiesOnce() throws {
        try withDefaults { d in
            d.set([0, 2], forKey: "relay.ticks.mailbox:mail.example.com.a1")
            d.set([1], forKey: "relay.ticks.mailbox:mail.example.com.b2")
            d.set("a1", forKey: "relay.panel.selection.mailbox:mail.example.com")
            d.set([5], forKey: "relay.ticks.mailbox:mail.example.com.other.c3")
            d.set([9], forKey: "relay.ticks.local.a1")
            d.set(true, forKey: "relay.closedToday.expanded")
            let current = "mailbox:mail.example.com#personal"

            SourceKey.migrate(d, from: "mailbox:mail.example.com", to: current)
            #expect(d.array(forKey: "relay.ticks.\(current).a1") as? [Int] == [0, 2])
            #expect(d.array(forKey: "relay.ticks.\(current).b2") as? [Int] == [1])
            #expect(d.string(forKey: "relay.panel.selection.\(current)") == "a1")
            #expect(d.object(forKey: "relay.ticks.\(current).other.c3") == nil)
            #expect(d.array(forKey: "relay.ticks.mailbox:mail.example.com.a1") as? [Int] == [0, 2])
            #expect(d.array(forKey: "relay.ticks.local.a1") as? [Int] == [9])
            #expect(d.bool(forKey: SourceKey.migratedFlag))

            d.set([4], forKey: "relay.ticks.mailbox:mail.example.com.d4")
            SourceKey.migrate(d, from: "mailbox:mail.example.com", to: current)
            #expect(d.object(forKey: "relay.ticks.\(current).d4") == nil)
        }
    }

    @Test func migrationNeverOverwrites() throws {
        try withDefaults { d in
            d.set([0], forKey: "relay.ticks.mailbox:m.a1")
            d.set([3], forKey: "relay.ticks.mailbox:m#p.a1")
            SourceKey.migrate(d, from: "mailbox:m", to: "mailbox:m#p")
            #expect(d.array(forKey: "relay.ticks.mailbox:m#p.a1") as? [Int] == [3])
        }
    }

    @Test func sameKeyOnlySetsTheFlag() throws {
        try withDefaults { d in
            SourceKey.migrate(d, from: "local", to: "local")
            #expect(d.bool(forKey: SourceKey.migratedFlag))
        }
    }
}
