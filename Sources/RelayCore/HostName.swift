import Foundation

/// Host-name comparison for "is this session on this Mac".
public enum HostName {
    /// This Mac's `gethostname()`, which is what the clients send as `from.host`.
    public static var current: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// Case-insensitive, on the first label: a Mac's name gains ".local" or a
    /// network's suffix depending on where it is.
    public static func same(_ a: String, _ b: String) -> Bool {
        let left = firstLabel(a), right = firstLabel(b)
        return !left.isEmpty && left == right
    }

    static func firstLabel(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}
