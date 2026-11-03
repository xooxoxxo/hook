import Foundation

/// What GitHub already knows about a crash signature.
public enum IssueMatch: Equatable, Sendable {
    /// No issue has the signature: open a new, prefilled one.
    case none
    /// An open issue has it: open it and copy a comment.
    case open(number: Int, title: String, url: URL)
    /// Closed under a milestone that is a release newer than the version that crashed.
    case closedFixed(number: Int, version: SemVer)
    /// Closed some other way: a new issue that says it's possibly the same.
    case closedOther(number: Int)
    /// Rate-limited (403, 429), a timeout, offline, or a reply Hook can't read.
    case unavailable
}

/// The GitHub path for everyone without My Pond. Before the owner submits anything in the
/// browser, the only thing that leaves the Mac is one unauthenticated search for the
/// signature, a 12-hex hash.
public struct GitHubIssues: Sendable {
    public static let defaultRepo = "xooxoxxo/hook"
    public static let defaultAPI = URL(string: "https://api.github.com")!
    static let web = "https://github.com"
    /// A prefilled issue link stays under about this many characters.
    public static let urlLimit = 6000

    let session: URLSession
    let repo: String
    let timeout: TimeInterval
    let api: URL

    public init(session: URLSession, repo: String = GitHubIssues.defaultRepo, timeout: TimeInterval = 5,
                api: URL = GitHubIssues.defaultAPI) {
        self.session = session
        self.repo = repo
        self.timeout = timeout
        self.api = api
    }

    /// `GET /search/issues?q=repo:<repo> "hook-crash-<sig>" in:body is:issue`, open and closed.
    /// Anyone can file an issue that quotes a signature, so only a trusted one counts: see
    /// `match`.
    public func search(signature: String, hookVersion: String) async -> IssueMatch {
        guard Self.isSignature(signature),
              var components = URLComponents(url: api.appending(path: "search/issues"), resolvingAgainstBaseURL: false)
        else { return .unavailable }
        components.queryItems = [URLQueryItem(name: "q", value: "repo:\(repo) \"hook-crash-\(signature)\" in:body is:issue")]
        guard let url = components.url else { return .unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hook", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(SearchReply.self, from: data) else { return .unavailable }
        return Self.match(reply.items, hookVersion: hookVersion, repo: repo)
    }

    /// The label a triager adds to vouch for an issue filed by someone without a role in the
    /// repo. It must never be in `.github/ISSUE_TEMPLATE/crash.md`: template labels go on
    /// anyone's issue.
    public static let confirmedLabel = "crash-confirmed"
    /// Repo roles whose issues count without the label.
    static let trustedAssociations: Set<String> = ["OWNER", "MEMBER", "COLLABORATOR"]

    /// The first trusted open issue wins. Else a closed one under a milestone that is a release
    /// newer than `hookVersion` is a fix (milestones are maintainer-only, so any author counts);
    /// else the first trusted closed one is "possibly the same". Items whose link isn't
    /// `https://github.com/<repo>/issues/<number>` are skipped.
    static func match(_ items: [SearchReply.Issue], hookVersion: String, repo: String = defaultRepo) -> IssueMatch {
        let items = items.filter { $0.html_url == "\(web)/\(repo)/issues/\($0.number)" }
        if let open = items.first(where: { $0.state == "open" && isTrusted($0) }), let url = URL(string: open.html_url) {
            return .open(number: open.number, title: open.title, url: url)
        }
        let closed = items.filter { $0.state == "closed" }
        let crashed = SemVer(strict: hookVersion)
        for issue in closed {
            if let title = issue.milestone?.title, let crashed,
               let fixed = SemVer(strict: title.hasPrefix("v") ? String(title.dropFirst()) : title), fixed > crashed {
                return .closedFixed(number: issue.number, version: fixed)
            }
        }
        if let other = closed.first(where: isTrusted) { return .closedOther(number: other.number) }
        return .none
    }

    /// Filed by the owner, a member or a collaborator, or labeled `confirmedLabel`.
    static func isTrusted(_ issue: SearchReply.Issue) -> Bool {
        trustedAssociations.contains(issue.author_association ?? "")
            || (issue.labels ?? []).contains { $0.name == confirmedLabel }
    }

    /// 12 lowercase hex, so nothing else can ride along in the query.
    static func isSignature(_ s: String) -> Bool {
        s.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    /// `github.com/<repo>/issues/new?template=crash.md&title=…&body=…`, the body's log lines
    /// dropped oldest first until the link fits `urlLimit`. `trimmed`: the full report should
    /// also go to the clipboard.
    public static func newIssueURL(title: String, body: String, repo: String = defaultRepo) -> (url: URL, trimmed: Bool) {
        func url(_ body: String) -> URL? {
            var components = URLComponents(string: "\(web)/\(repo)/issues/new")
            components?.queryItems = [URLQueryItem(name: "template", value: "crash.md"),
                                      URLQueryItem(name: "title", value: title),
                                      URLQueryItem(name: "body", value: body)]
            // `+` reads as a space in a query: encode it, as GitHub expects.
            let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            components?.percentEncodedQuery = query
            return components?.url
        }
        let fitted = CrashReportText.fit(body) { (url($0)?.absoluteString.count ?? .max) <= urlLimit }
        // A fence the cut left open is closed again, so the issue still renders as code.
        var text = fitted.text
        if fitted.trimmed, text.components(separatedBy: "```").count % 2 == 0 {
            let closed = CrashReportText.fit(text) { (url($0 + "\n```\n")?.absoluteString.count ?? .max) <= urlLimit }
            text = closed.text + "\n```\n"
        }
        return (url(text) ?? URL(string: "\(web)/\(repo)/issues/new")!, fitted.trimmed)
    }

    /// The issue list filtered to the signature: "Check for an Existing Issue" when the search
    /// couldn't run.
    public static func searchPageURL(signature: String, repo: String = defaultRepo) -> URL {
        var components = URLComponents(string: "\(web)/\(repo)/issues")
        components?.queryItems = [URLQueryItem(name: "q", value: "is:issue \"hook-crash-\(signature)\"")]
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: ":", with: "%3A")
        components?.percentEncodedQuery = query
        return components?.url ?? URL(string: "\(web)/\(repo)/issues")!
    }

    /// A new issue's body: the report in a text fence, after "Possibly the same as #N" when a
    /// closed issue has the signature. The report's own signature line is what the search finds.
    public static func issueBody(_ report: String, sameAs: Int?) -> String {
        (sameAs.map { "Possibly the same as #\($0)\n\n" } ?? "") + fenced(report)
    }

    /// The comment for an open issue; GitHub can't prefill comments, so it goes to the clipboard.
    public static func comment(_ report: String) -> String {
        "This crash happened again.\n\n" + fenced(report)
    }

    static func fenced(_ report: String) -> String { "```text\n" + report + "\n```\n" }

    struct SearchReply: Decodable {
        struct Issue: Decodable {
            struct Milestone: Decodable { let title: String? }
            struct Label: Decodable { let name: String? }
            let number: Int
            let title: String
            let state: String
            let html_url: String
            let milestone: Milestone?
            /// Missing in a reply: trusts nothing.
            let author_association: String?
            let labels: [Label]?
        }
        let items: [Issue]
    }
}
