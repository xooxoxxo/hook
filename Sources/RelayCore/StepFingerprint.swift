import CryptoKit
import Foundation

/// A tick's guard: a stored tick applies to a leaf only when the leaf's
/// fingerprint matches, so a re-posted ask never shows a tick on a different step.
public enum StepFingerprint {
    public enum Kind: String, Sendable { case step, sub, verify }

    /// The first 16 lowercase hex characters of SHA-256 over
    /// `[parent + US] + kind + US + do + US + (where ?? "") + US + (code ?? "")`, US = U+001F.
    public static func make(kind: Kind, action: String, place: String?, code: String?, parent: String? = nil) -> String {
        let separator = "\u{1F}"
        var input = parent.map { $0 + separator } ?? ""
        input += kind.rawValue + separator + action + separator + (place ?? "") + separator + (code ?? "")
        let digest = SHA256.hash(data: Data(input.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
