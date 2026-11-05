import AppKit
import RelayCore
import Testing
import UserNotifications
@testable import RelayUI

/// The colour fish on the hook rides on every notification that announces asks, and on no other.
@Suite @MainActor struct AskNotificationImageTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hook-ask-fish-\(UUID().uuidString)")
    }

    private func fishIDs(_ note: UNNotificationContent) -> [String] {
        note.attachments.map(\.identifier)
    }

    @Test func theBundledImageIsASquareColourPNG() throws {
        let url = try #require(AskNotificationImage.bundledURL())
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(rep.pixelsWide == 256 && rep.pixelsHigh == 256)
        // Not a template: the centre of the fish is lime, not black.
        let c = try #require(rep.colorAt(x: 128, y: 200)?.usingColorSpace(.sRGB))
        #expect(c.greenComponent > 0.6 && c.blueComponent < 0.3)
    }

    @Test func eachNotificationGetsItsOwnCopy() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try #require(AskNotificationImage.freshCopy(in: dir))
        let b = try #require(AskNotificationImage.freshCopy(in: dir))
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        #expect(try Data(contentsOf: a) == Data(contentsOf: try #require(AskNotificationImage.bundledURL())))
    }

    @Test func oneNewAskCarriesTheFish() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = NotificationContentMaker.asks(
            .single(id: "a1", project: "Site", title: "Approve the DNS change"), sound: true, images: dir)
        #expect(made.identifier == "a1")
        #expect(made.content.userInfo["id"] as? String == "a1")
        #expect(fishIDs(made.content) == [AskNotificationImage.attachmentIdentifier])
    }

    @Test func manyNewAsksCarryTheFish() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = NotificationContentMaker.asks(.many(3), sound: false, images: dir)
        #expect(made.content.body == "3 new asks")
        #expect(fishIDs(made.content) == [AskNotificationImage.attachmentIdentifier])
    }

    @Test func theAwaySummaryCarriesTheFish() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = NotificationContentMaker.awaySummary(
            "2 asks arrived while you were away", first: "a1", sound: false, images: dir)
        #expect(made.content.userInfo["first"] as? String == "a1")
        #expect(fishIDs(made.content) == [AskNotificationImage.attachmentIdentifier])
    }

    @Test func closedAskFeedbackIsQuietAndContainsNoAskText() {
        let note = NotificationContentMaker.closedAsk(id: "closed-1", canShowClosed: true)
        #expect(note.body == "This ask is already closed.")
        #expect(note.sound == nil && note.attachments.isEmpty)
        #expect(note.userInfo["closedId"] as? String == "closed-1")
        #expect(note.userInfo["id"] == nil)
        let missing = NotificationContentMaker.closedAsk(id: "gone", canShowClosed: false)
        #expect(missing.userInfo.isEmpty)
    }

    @Test func otherNoticesCarryNothing() {
        #expect(NotificationContentMaker.crashNotice().attachments.isEmpty)
        #expect(NotificationContentMaker.testNotice(sound: true).attachments.isEmpty)
    }
}
