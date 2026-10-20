import Foundation

/// How a step URL or a link is titled, and whether it may open (http and https only).
public enum LinkDisplay {
    /// The validator's http(s) rule, plus a host Foundation can parse, so it can open.
    public static func isWeb(_ url: String) -> Bool {
        guard Validator.isHTTPURL(url), let host = URL(string: url)?.host(percentEncoded: false) else { return false }
        return !host.isEmpty
    }

    public static func host(_ url: String) -> String? {
        guard var host = URL(string: url)?.host(percentEncoded: false), !host.isEmpty else { return nil }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public static func stepTitle(_ url: String) -> String? {
        guard isWeb(url), let host = host(url) else { return nil }
        return "Open " + Sanitize.revealLine(host) + warning(host)
    }

    public static func linkTitle(label: String, url: String) -> String {
        let host = host(url) ?? url
        return Sanitize.revealLine(label) + " · " + Sanitize.revealLine(host) + warning(host)
    }

    public static func refusedText(label: String?) -> String {
        guard let label else { return "Link not shown: only http and https open here" }
        return Sanitize.revealLine(label) + " (not a web address)"
    }

    /// Foundation stores an internationalized host as punycode ("xn--…").
    static func warning(_ host: String) -> String {
        let nonASCII = !host.allSatisfy(\.isASCII)
            || host.lowercased().split(separator: ".").contains { $0.hasPrefix("xn--") }
        return nonASCII ? " ⚠︎ non-ASCII host" : ""
    }
}
