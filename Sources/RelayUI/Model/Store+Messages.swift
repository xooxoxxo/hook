import Foundation
import RelayCore

/// Messages to the posting session (Pond 1.2.0, pick 4 A).
extension Store {
    /// The ask takes a message now: a Pond with messages, and the ask is open.
    func canMessage(_ id: String) -> Bool {
        talk.messages && item(for: id)?.status == "open"
    }

    /// Sends `text` as typed. On success the draft clears (if it still reads the same) and the
    /// ask reloads, so the message shows; a refusal keeps the draft and says why. Nothing else
    /// moves: no reply, answer, tick or close.
    @discardableResult public func sendMessage(_ id: String, text: String) async -> Bool {
        guard canMessage(id), MessageText.canSend(text), messageStates[id] != .sending, let source else { return false }
        HookLog.action(.message)
        messageStates[id] = .sending
        let gen = generation
        do {
            _ = try await source.message(id, text: text)
            guard gen == generation else { return true }
            messageStates[id] = nil
            if messageDrafts[id] == text { messageDrafts[id] = nil }
            await reload(id)
            return true
        } catch {
            guard gen == generation else { return false }
            _ = ownerKeyRefused(error)
            messageStates[id] = .failed(MessageText.refusal(error))
            return false
        }
    }

    /// The queue row's Message Session…: the ask opens and its Messages field takes focus.
    public func messageSession(_ id: String) {
        guard canMessage(id) else { return }
        if navigation.selectedID != id { open(id) }
        messageFocus = id
    }
}
