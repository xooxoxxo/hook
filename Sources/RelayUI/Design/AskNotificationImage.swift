import Foundation
import RelayCore
import UniformTypeIdentifiers
import UserNotifications

/// The colour fish on the hook that a notification about asks carries as its thumbnail. A banner
/// always shows the app icon (the hook and the worm) on the left, whatever it announces; the
/// attachment shows on the right, so an ask reads as an ask at a glance.
///
/// The image is `Resources/Notification/ask-fish.svg`, the menu-bar fish in the app icon's
/// colours, rendered to a 256 px PNG by `scripts/menubar-glyphs.sh` and bundled like the glyphs.
public enum AskNotificationImage {
    public static let fileName = "ask-fish.png"
    /// The attachment's identifier on every notification that carries the fish.
    public static let attachmentIdentifier = "hook.ask-fish"

    /// The bundled PNG, or nil when the bundle lacks it (the notification then goes out without).
    public static func bundledURL() -> URL? {
        BundledResources.folder("Notification", containing: fileName)?.appending(path: fileName)
    }

    /// `~/Library/Caches/Relay/Notification`: where each notification's copy waits until macOS
    /// takes it.
    public static var defaultFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "Relay/Notification", directoryHint: .isDirectory)
    }

    /// A fresh copy of the PNG in `folder`, one per notification: adding a request moves an
    /// attachment's file into the notification store, so the bundled file is never handed over.
    public static func freshCopy(in folder: URL) -> URL? {
        guard let source = bundledURL() else { return nil }
        let copy = folder.appending(path: "ask-fish-\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// The attachment for one notification, or nil when the image is missing or refused.
    public static func attachment(in folder: URL) -> UNNotificationAttachment? {
        guard let url = freshCopy(in: folder) else { return nil }
        do {
            return try UNNotificationAttachment(
                identifier: attachmentIdentifier, url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}

/// What each notification Hook posts says and carries. The ones that announce asks (one new
/// ask, "N new asks", the away summary) carry the fish; the crash notice and Settings' test
/// notification carry nothing.
public enum NotificationContentMaker {
    /// One new ask, or "N new asks". The identifier is the ask id for one ask, so a banner can be
    /// removed when the ask closes.
    public static func asks(_ content: NotifyContent, sound: Bool, images: URL)
        -> (content: UNMutableNotificationContent, identifier: String) {
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        let identifier: String
        switch content {
        case let .single(id, project, _):
            note.threadIdentifier = project.isEmpty ? "relay" : project
            note.userInfo = ["id": id]
            identifier = id
        case .many:
            note.threadIdentifier = "relay"
            identifier = "relay.many.\(UUID().uuidString)"
        }
        if sound { note.sound = .default }
        attachFish(note, images: images)
        return (note, identifier)
    }

    /// "3 asks arrived while you were away". A click opens the list with `first` selected.
    public static func awaySummary(_ text: String, first: String?, sound: Bool, images: URL)
        -> (content: UNMutableNotificationContent, identifier: String) {
        let note = UNMutableNotificationContent()
        note.title = "Hook"
        note.body = text
        note.threadIdentifier = "relay"
        note.userInfo = first.map { ["first": $0] } ?? [:]
        if sound { note.sound = .default }
        attachFish(note, images: images)
        return (note, "relay.away.\(UUID().uuidString)")
    }

    public static func closedAsk(id: String, canShowClosed: Bool) -> UNMutableNotificationContent {
        let note = UNMutableNotificationContent()
        note.title = "Hook"
        note.body = "This ask is already closed."
        note.threadIdentifier = "hook.closed"
        if canShowClosed { note.userInfo = ["closedId": id] }
        return note
    }

    public static func crashNotice() -> UNMutableNotificationContent {
        let note = UNMutableNotificationContent()
        note.title = "Hook quit unexpectedly"
        note.body = "Open Hook to review the crash report. Nothing has been sent."
        note.threadIdentifier = "relay"
        return note
    }

    /// Settings › Notifications › Send Test Notification.
    public static func testNotice(sound: Bool) -> UNMutableNotificationContent {
        let note = UNMutableNotificationContent()
        note.title = "Hook"
        note.body = "Notifications work."
        if sound { note.sound = .default }
        return note
    }

    private static func attachFish(_ note: UNMutableNotificationContent, images: URL) {
        if let fish = AskNotificationImage.attachment(in: images) { note.attachments = [fish] }
    }
}
