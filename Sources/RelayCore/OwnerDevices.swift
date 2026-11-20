import Foundation

/// A revoke the owner confirms on Telegram (`OwnerKeyFlow.requestRevoke`), for a Mac without a
/// working owner key: sent, waiting for the tap (with the code Telegram repeats), and how it ended.
public enum RevokeRequestState: Equatable, Sendable {
    case idle
    case sending(keyID: String)
    case waiting(keyID: String, requestID: String, code: String, expires: Date?)
    /// The owner tapped Revoke: the device is gone.
    case revoked(keyID: String)
    /// Turned down, expired or refused; `reason` is one line for the sheet.
    case ended(keyID: String, reason: String)

    /// Sending or waiting: a second request waits for this one.
    public var isActive: Bool {
        switch self {
        case .sending, .waiting: return true
        case .idle, .revoked, .ended: return false
        }
    }

    public var keyID: String? {
        switch self {
        case .idle: return nil
        case .sending(let id), .waiting(let id, _, _, _), .revoked(let id), .ended(let id, _): return id
        }
    }
}

/// How the Devices sheet revokes a device.
public enum DeviceRevokePath: Equatable, Sendable {
    /// `POST /owner/revoke` with this Mac's approved key.
    case ownerKey
    /// `POST /owner/revoke-request`: the owner confirms on Telegram.
    case telegram
    /// No working key and a Pond without `ownerRevokeRequest`.
    case unavailable
}

/// One row of the Devices sheet.
public struct DeviceRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isThisMac: Bool
    public var pending: Bool
    /// "4 Nov"; nil when the Pond's dates aren't shown or don't read.
    public var setUp: String?
    /// "Today", "4 Nov", "—"; nil when the Pond's dates aren't shown.
    public var lastUsed: String?
    public var created: Date?

    public init(id: String, name: String, isThisMac: Bool = false, pending: Bool = false, setUp: String? = nil,
                lastUsed: String? = nil, created: Date? = nil) {
        self.id = id; self.name = name; self.isThisMac = isThisMac; self.pending = pending
        self.setUp = setUp; self.lastUsed = lastUsed; self.created = created
    }
}

/// The Devices sheet's pure logic: rows, their order, the slots line and the revoke path.
public enum OwnerDevices {
    /// Which way a revoke goes: this Mac's approved key first; without one, Telegram when the Pond
    /// lists `ownerRevokeRequest`.
    public static func revokePath(state: OwnerKeyState, status: OwnerStatus?,
                                  capabilities: PondCapabilities?) -> DeviceRevokePath {
        if state == .approved, status?.self_?.status == "approved" { return .ownerKey }
        if capabilities?.supports(.ownerRevokeRequest) == true { return .telegram }
        return .unavailable
    }

    /// The Pond sends `created`, `lastUsed` and `maxKeys` (`ownerKeyDates`). Without it the
    /// sheet shows names only.
    public static func showsDates(_ capabilities: PondCapabilities?) -> Bool {
        capabilities?.supports(.ownerKeyDates) == true
    }

    /// This Mac first, then newest set up first; a key without a readable date goes last, by label.
    public static func rows(_ status: OwnerStatus?, dates: Bool, now: Date = Date(), locale: Locale = .current,
                            timeZone: TimeZone = .current) -> [DeviceRow] {
        guard let status else { return [] }
        let mine = status.self_?.id
        let rows = status.keys.map { key -> DeviceRow in
            let created = Timestamp.date(key.created)
            let pending = key.status != "approved"
            var row = DeviceRow(id: key.id, name: Sanitize.revealLine(key.label), isThisMac: key.id == mine,
                                pending: pending, created: created)
            if dates {
                row.setUp = created.map { day($0, now: now, locale: locale, timeZone: timeZone) } ?? "—"
                if pending {
                    row.lastUsed = waiting
                } else {
                    row.lastUsed = key.lastUsed.flatMap(Timestamp.date)
                        .map { lastUsedText($0, now: now, locale: locale, timeZone: timeZone) } ?? "—"
                }
            }
            return row
        }
        return rows.sorted { a, b in
            if a.isThisMac != b.isThisMac { return a.isThisMac }
            switch (a.created, b.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// "3 of 10 slots used", or "3 devices" from a Pond that doesn't say its limit. Every key the
    /// Pond lists (approved and waiting) holds a slot.
    public static func slots(_ status: OwnerStatus?) -> String {
        let used = status?.keys.count ?? 0
        if let max = status?.maxKeys { return "\(used) of \(max) slots used" }
        return used == 1 ? "1 device" : "\(used) devices"
    }

    /// Every slot is taken (from a Pond that says its limit).
    public static func full(_ status: OwnerStatus?) -> Bool {
        guard let status, let max = status.maxKeys else { return false }
        return status.keys.count >= max
    }

    public static let waiting = "Waiting"

    /// "4 Nov", or "4 Nov 2025" outside this year.
    static func day(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// "Today", "Yesterday", else the day.
    static func lastUsedText(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day(date, now: now, locale: locale, timeZone: timeZone)
    }

    // MARK: - The revoke request's words

    public static let revokeDeclined = "The revoke was turned down on Telegram."
    public static let revokeExpired = "The revoke request expired before it was confirmed."
    public static let revokeGone = "The Pond no longer lists this device."
    public static let revokeAlreadyPending =
        "Another revoke is already waiting on Telegram. Answer it there, or try again once it expires."
    public static let revokeAlreadyRevoked = "This device is already revoked."
    public static let revokeNotApproved =
        "This device was never approved, so it can't act as you. Its request expires on its own."
    public static let revokeTelegramFailed = "The Pond couldn't reach Telegram. Try again in a moment."
    public static let revokeRateLimited = "Too many requests. Try again in a few minutes."
    public static let revokeNotSupported = "This Pond can't confirm a revoke on Telegram. Update the Pond."

    /// Why `POST /owner/revoke-request` failed, as one line; `gone` when the list is stale.
    public static func requestRefused(_ error: any Error) -> (reason: String, gone: Bool) {
        switch error as? QueueError {
        case .notFound?: return (revokeGone, true)
        case .rejected(409, "revoke request pending", _)?: return (revokeAlreadyPending, false)
        case .rejected(409, "already revoked", _)?: return (revokeAlreadyRevoked, true)
        case .rejected(409, "not approved", _)?: return (revokeNotApproved, false)
        case .rejected(409, _, _)?: return (revokeGone, true)
        case .rejected(502, _, _)?: return (revokeTelegramFailed, false)
        case .rejected(429, _, _)?: return (revokeRateLimited, false)
        case .rejected(501, _, _)?: return (revokeNotSupported, false)
        default: return ("Couldn't send the request: " + UserFacingError.text(error), false)
        }
    }

    /// A code the sheet may show: six digits.
    public static func validCode(_ code: String?) -> String? {
        guard let code, code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return code
    }
}
