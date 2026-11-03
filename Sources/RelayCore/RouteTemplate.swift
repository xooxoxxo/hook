import Foundation

/// A request path with its ids taken out, for the log: `asks/<uuid>/reply` → `asks/{id}/reply`.
/// The host and the query never appear.
public enum RouteTemplate {
    public static func template(_ path: String) -> String {
        var path = path
        if path.contains("://"), let url = URL(string: path) { path = url.path }
        if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            let s = String(segment)
            return isName(s) ? s : "{id}"
        }
        return segments.joined(separator: "/")
    }

    /// A short lowercase word such as `asks` or `revisions`; anything else (a uuid, a number,
    /// a long hex run, free text) is an id.
    private static func isName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 32 else { return false }
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "_" || $0 == ".") }) else { return false }
        return true
    }
}
