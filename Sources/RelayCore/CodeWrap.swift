import Foundation

/// Whether a code block soft-wraps its lines. Plain text (`lang` "text", any
/// case, or no language) wraps; every other language stays exact and scrolls
/// sideways. Wrapping is display only: Copy always takes the original text.
public enum CodeWrap {
    public static func shouldWrap(lang: String?) -> Bool {
        let name = (lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.lowercased() == "text"
    }
}
