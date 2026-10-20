import Foundation

/// Every error that reaches a `Text`: one revealed line, so a reason from
/// the mailbox or the disk can't break the layout or hide characters.
public enum UserFacingError {
    public static func text(_ error: any Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription { return text(described) }
        if type(of: error) is NSError.Type { return text((error as NSError).localizedDescription) }
        return text(String(describing: error))
    }

    public static func text(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown error" : Sanitize.revealLine(trimmed)
    }
}
