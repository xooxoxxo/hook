import Foundation
import RelayCore

/// Reads the mailbox's `GET /version`: on connect, when the source changes, then at most
/// every 30 minutes while the mailbox is reachable (`MailboxCheckSchedule`). This Mac mode
/// needs no check: the app is its own server.
@MainActor final class MailboxChecker {
    private(set) var last: MailboxCheck?
    private(set) var checking = false
    /// Called after every check, manual or not, with the check and whether it was manual.
    var onResult: (@MainActor (MailboxCheck, Bool) -> Void)?
    /// Called when a check starts, so the Settings row can show it.
    var onStart: (@MainActor () -> Void)?
    private var inFlight: Task<MailboxCheck, Never>?
    private var observedKey: String?
    private var wasReachable = false

    /// After every Store change: starts a check when one is due.
    func observe(sourceKey: String, settings: MailboxSettings?, reachable: Bool) {
        let becameReachable = reachable && (!wasReachable || observedKey != sourceKey)
        if observedKey != sourceKey, !sourceKey.hasPrefix("mailbox:") { last = nil }
        observedKey = sourceKey
        wasReachable = reachable
        guard let settings, inFlight == nil,
              MailboxCheckSchedule.isDue(last: last, sourceKey: sourceKey, reachable: reachable,
                                         becameReachable: becameReachable, now: Date()) else { return }
        Task { @MainActor in _ = await self.check(settings, sourceKey: sourceKey, manual: false) }
    }

    /// One check now; a check already running is joined.
    @discardableResult
    func check(_ settings: MailboxSettings, sourceKey: String, manual: Bool) async -> MailboxCheck {
        if let inFlight {
            let joined = await inFlight.value
            if manual { onResult?(joined, true) }   // the joined check reported as not manual
            return joined
        }
        checking = true
        onStart?()
        let task = Task { @MainActor () -> MailboxCheck in
            let result: MailboxCheck.Result
            do {
                result = .version(try await MailboxClient(settings: settings).version())
            } catch {
                result = .failed(reason: UserFacingError.text(error))
            }
            return MailboxCheck(sourceKey: sourceKey, result: result, checkedAt: Date())
        }
        inFlight = task
        let check = await task.value
        inFlight = nil
        checking = false
        // A source switched away during the check: its result is dropped.
        if observedKey == nil || observedKey == sourceKey {
            last = check
            onResult?(check, manual)
        }
        return check
    }

    /// Settings' Mailbox row for the current source.
    func line(sourceKey: String) -> MailboxVersionLine? {
        guard sourceKey.hasPrefix("mailbox:") else { return nil }
        return MailboxVersionLine.line(last?.sourceKey == sourceKey ? last : nil, checking: checking)
    }
}
