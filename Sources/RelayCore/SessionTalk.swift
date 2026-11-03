import Foundation

/// What Hook can say to the session that posted an ask: problem reports on a step (Pond
/// 1.1.0) and messages (Pond 1.2.0). Neither on This Mac, whose queue has no session channel.
public struct SessionTalk: Equatable, Sendable {
    /// Report a Problem on a step.
    public var reports: Bool
    /// The Messages section and Message Session….
    public var messages: Bool

    public init(reports: Bool = false, messages: Bool = false) {
        self.reports = reports
        self.messages = messages
    }

    public static let none = SessionTalk()

    /// A Pond source only. Reports need 1.1.0, which this Hook requires anyway, so a Pond whose
    /// version check hasn't answered yet counts as having them; messages wait for the check.
    public static func make(sourceKey: String, pond: PondVersion?) -> SessionTalk {
        guard sourceKey.hasPrefix("mailbox:") else { return .none }
        return SessionTalk(reports: pond?.supports(.corrections) ?? true, messages: pond?.supports(.messages) ?? false)
    }
}
