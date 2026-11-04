import Foundation
import RelayCore

/// "Required before Done" (Pond 1.3.0) asks for the gallery and the tests. Generic text only.
public enum RequiredFixtures {
    public static let id = "00000000-0000-4000-8000-0000000013a1"
    static let locale = Locale(identifier: "en_GB")
    static let timeZone = TimeZone(identifier: "UTC")!

    /// Step 1 required (finished in every state), 2 a required command, 3 a required question,
    /// 4 a parent whose sub-step 4a is required, 5 optional; a reply prompt; `done` as given.
    static func json(done: String, reply: String, steps: String = fullSteps, events: String) -> String {
        #"""
        {"item": {"id": "ID", "title": "Rotate the staging deploy key",
          "status": "open", "projectId": "Atlas", "created": "2026-10-16T07:40:00+00:00", "updated": "2026-10-16T07:40:00+00:00",
          "payload": {"instructable": {"v": 1, "title": "Rotate the staging deploy key", "urgency": "today",
            "why": "The old key expires on Friday and the deploy job will stop.",
            "steps": STEPS,
            "reply": REPLY,
            "done": DONE,
            "from": {"session": "1b2c3d4e-0000-4000-8000-000000000001", "host": "example-mac", "cwd": "/work/atlas"}}}},
         "events": [EVENTS]}
        """#
            .replacingOccurrences(of: "ID", with: id)
            .replacingOccurrences(of: "STEPS", with: steps)
            .replacingOccurrences(of: "REPLY", with: reply)
            .replacingOccurrences(of: "DONE", with: done)
            .replacingOccurrences(of: "EVENTS", with: events)
    }

    static let fullSteps = #"""
        [{"id": "s1", "do": "Open the staging vault", "url": "https://vault.example.com/staging", "required": true},
         {"id": "s2", "do": "Generate a new deploy key", "where": "Mac terminal", "required": true,
          "code": "ssh-keygen -t ed25519 -f ~/.ssh/atlas-deploy -C deploy@staging",
          "expect": "Your identification has been saved"},
         {"id": "s3", "do": "Confirm the old key is revoked", "required": true,
          "question": {"prompt": "Is the old key revoked in the vault?", "choices": ["Yes", "Not yet"]}},
         {"id": "s4", "do": "Update the deploy job", "substeps": [
           {"id": "s4a", "do": "Paste the public key into the job settings", "required": true},
           {"id": "s4b", "do": "Re-run the last deploy"}]},
         {"id": "s5", "do": "Delete the old key file", "optional": true, "code": "rm ~/.ssh/atlas-deploy-old"}]
        """#

    /// Three plain steps, nothing required on them.
    static let plainSteps = #"""
        [{"id": "s1", "do": "Open the staging vault", "url": "https://vault.example.com/staging"},
         {"id": "s2", "do": "Generate a new deploy key", "where": "Mac terminal",
          "code": "ssh-keygen -t ed25519 -f ~/.ssh/atlas-deploy -C deploy@staging"},
         {"id": "s3", "do": "Paste the public key into the job settings"}]
        """#

    static let freeReply = #"{"prompt": "What did the dry run print?"}"#
    static let choiceReply = #"{"prompt": "Did the dry run pass?", "choices": ["Yes", "No"]}"#

    static func event(_ seq: Int, _ kind: String, _ text: String, at minute: Int) -> String {
        let body = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"seq": \#(seq), "itemId": "\#(id)", "kind": "\#(kind)", "actor": "owner", "text": "\#(body)", "#
            + #""at": "2026-10-16T09:\#(minute):00+00:00", "rev": 1, "auth": "token"}"#
    }

    static var answerYes: String {
        event(1, "answer", String(decoding: Answers.entry(step: "3", picked: ["Yes"]).data(), as: UTF8.self), at: 12)
    }
    static let replied = event(2, "reply", "0 changes, 12 hosts reachable.", at: 14)
    static let messaged = event(3, "message", "The old key is gone from the vault too.", at: 15)

    /// The full ask with `done: ["reply", "message"]`. Left: step 1 ticked only, so 2, 3, 4a, the
    /// reply and a message are left. Ready: everything finished.
    public static func full(ready: Bool) -> DetailSnapshot {
        let events = ready ? [answerYes, replied, messaged].joined(separator: ",") : ""
        return snapshot(json(done: #"["reply", "message"]"#, reply: freeReply, events: events),
                        ticks: ready ? ["1", "2", "4.1", "4.2"] : ["1"])
    }

    /// Plain steps, all ticked, a choice reply prompt and `done: ["message"]`, no message yet:
    /// the Messages field is inline (RD 27) and marked.
    public static var messageLeft: DetailSnapshot {
        snapshot(json(done: #"["message"]"#, reply: choiceReply, steps: plainSteps, events: ""), ticks: ["1", "2", "3"])
    }

    /// Plain steps, all ticked, and `done: ["reply"]`, not replied yet: the reply is marked.
    public static var replyLeft: DetailSnapshot {
        snapshot(json(done: #"["reply"]"#, reply: choiceReply, steps: plainSteps, events: ""), ticks: ["1", "2", "3"])
    }

    /// `json` decoded and built as the Store builds it, from a Pond with messages.
    public static func snapshot(_ json: String, ticks: Set<String>) -> DetailSnapshot {
        let detail: AskDetail
        do {
            detail = try JSONDecoder().decode(AskDetail.self, from: Data(json.utf8))
        } catch {
            fatalError("required fixture does not decode: \(error)")
        }
        var snapshot = DetailSnapshot.build(
            item: detail.item, detail: detail, ticks: ticks, load: .loaded, reply: .idle, draft: nil,
            pendingChoice: nil, busy: false, previous: .end, next: .end, closedBy: nil)
        snapshot.replies = ReplyText.lines(events: detail.events, locale: locale, timeZone: timeZone)
        snapshot.messages = MessageText.lines(events: detail.events, locale: locale, timeZone: timeZone)
        snapshot.canMessage = true
        return snapshot
    }
}
