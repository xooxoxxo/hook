import Foundation

/// The setup window's and About window's links. The agent checks moved to `relay
/// integrations` (IntegrationStatus), which covers every harness, not only Claude Code.
extension ConnectInfo {
    /// The Support Hook button's link on the setup window's last page. Empty, or anything
    /// that isn't an https link, hides the button.
    public static let donationURL = "https://ko-fi.com/xo-vision"
    /// The About window's project link.
    public static let projectURL = "https://github.com/xooxoxxo/hook"
    public static let projectLabel = "github.com/xooxoxxo/hook"
    public static var projectLink: URL? { URL(string: projectURL) }

    public static func donationLink(_ raw: String = donationURL) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return url
    }
}
