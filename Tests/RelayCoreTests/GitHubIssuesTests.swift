import Foundation
import Testing
@testable import RelayCore

private let signature = "a3f9c2e17b04"

private func searchFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "github-search-" + name, withExtension: "json",
                                             subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// A GitHubIssues whose API host is unique to the test and answered by the stub.
private func issues(_ handler: @escaping MailboxStubRegistry.Handler) throws -> (GitHubIssues, String) {
    let host = "gh-" + UUID().uuidString.lowercased() + ".test"
    MailboxStubRegistry.shared.register(host, handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MailboxStubProtocol.self]
    let api = try #require(URL(string: "https://\(host)"))
    return (GitHubIssues(session: URLSession(configuration: configuration), api: api), host)
}

@Suite struct GitHubIssuesTests {
    @Test(arguments: [
        ("none", IssueMatch.none),
        ("open", .open(number: 42, title: "Hook crash: EXC_BAD_ACCESS in SettingsWindow.open (a3f9c2e17b04)",
                       url: URL(string: "https://github.com/xooxoxxo/hook/issues/42")!)),
        ("closed-fixed", .closedFixed(number: 42, version: SemVer(major: 0, minor: 12, patch: 1))),
        ("closed-other", .closedOther(number: 38)),
    ])
    func matches(_ name: String, _ expected: IssueMatch) async throws {
        let body = try searchFixture(name)
        let (gh, _) = try issues { _, _ in (200, body) }
        #expect(await gh.search(signature: signature, hookVersion: "0.12.0") == expected)
    }

    /// A fix released in the version that crashed (or earlier) didn't fix this crash.
    @Test func aMilestoneNotNewerThanTheCrashIsNotAFix() async throws {
        let body = try searchFixture("closed-fixed")
        let (gh, _) = try issues { _, _ in (200, body) }
        #expect(await gh.search(signature: signature, hookVersion: "0.12.1") == .closedOther(number: 42))
    }

    @Test(arguments: [403, 429, 500])
    func refusalsAreUnavailable(_ status: Int) async throws {
        let (gh, _) = try issues { _, _ in (status, #"{"message":"API rate limit exceeded"}"#) }
        #expect(await gh.search(signature: signature, hookVersion: "0.12.0") == .unavailable)
    }

    @Test(arguments: [URLError.Code.timedOut, .notConnectedToInternet])
    func timeoutsAndOfflineAreUnavailable(_ code: URLError.Code) async throws {
        let (gh, _) = try issues { _, _ in throw URLError(code) }
        #expect(await gh.search(signature: signature, hookVersion: "0.12.0") == .unavailable)
    }

    @Test func garbageIsUnavailable() async throws {
        let (gh, _) = try issues { _, _ in (200, "not json") }
        #expect(await gh.search(signature: signature, hookVersion: "0.12.0") == .unavailable)
    }

    /// One unauthenticated GET whose query holds the signature and nothing else of the Mac's.
    @Test func theQueryIsExactAndCarriesOnlyTheSignature() async throws {
        let body = try searchFixture("none")
        let (gh, host) = try issues { _, _ in (200, body) }
        _ = await gh.search(signature: signature, hookVersion: "0.12.0")
        let sent = try #require(MailboxStubRegistry.shared.last(host))
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.url?.path() == "/search/issues")
        let items = URLComponents(url: try #require(sent.request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "q", value: #"repo:xooxoxxo/hook "hook-crash-a3f9c2e17b04" in:body is:issue"#)])
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.body.isEmpty)
        #expect(sent.request.timeoutInterval == 5)
    }

    @Test func aSignatureThatIsntOneIsNeverSent() async throws {
        let (gh, host) = try issues { _, _ in (200, #"{"items":[]}"#) }
        #expect(await gh.search(signature: "x\" OR repo:other", hookVersion: "0.12.0") == .unavailable)
        #expect(MailboxStubRegistry.shared.last(host)?.request == nil)
    }

    @Test func theDefaultsPointAtTheHookRepo() {
        #expect(GitHubIssues.defaultAPI.absoluteString == "https://api.github.com")
        #expect(GitHubIssues.defaultRepo == "xooxoxxo/hook")
        #expect(GitHubIssues.searchPageURL(signature: signature).absoluteString
            == "https://github.com/xooxoxxo/hook/issues?q=is%3Aissue%20%22hook-crash-a3f9c2e17b04%22")
    }

    @Test func aNewIssueURLIsPrefilledFromTheTemplate() throws {
        let made = GitHubIssues.newIssueURL(title: "Hook crash: X (\(signature))", body: "short body")
        #expect(!made.trimmed)
        let items = URLComponents(url: made.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(made.url.host() == "github.com")
        #expect(made.url.path() == "/xooxoxxo/hook/issues/new")
        #expect(items.first { $0.name == "template" }?.value == "crash.md")
        #expect(items.first { $0.name == "title" }?.value == "Hook crash: X (\(signature))")
        #expect(items.first { $0.name == "body" }?.value == "short body")
    }

    /// Past ~6,000 characters the log goes, oldest first; the title and signature line stay.
    @Test func theURLCapTrimsLogLinesOldestFirst() throws {
        let report = (["Hook crash: X (\(signature))", CrashReportText.signatureLine(signature), "",
                       "Last 300 log lines"] + (1...300).map { "2026-10-15T22:00:00Z action open line=\($0) " })
            .joined(separator: "\n")
        let body = GitHubIssues.issueBody(report, sameAs: nil)
        let made = GitHubIssues.newIssueURL(title: "Hook crash: X (\(signature))", body: body)
        #expect(made.trimmed)
        #expect(made.url.absoluteString.count <= GitHubIssues.urlLimit)
        let sentBody = try #require(URLComponents(url: made.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value)
        #expect(sentBody.contains(CrashReportText.signatureLine(signature)))
        #expect(sentBody.contains("line=300 "))
        #expect(!sentBody.contains("line=1 "))
        #expect(sentBody.hasSuffix("```\n"))
    }

    @Test func bodiesAndComments() {
        #expect(GitHubIssues.issueBody("R", sameAs: nil) == "```text\nR\n```\n")
        #expect(GitHubIssues.issueBody("R", sameAs: 38) == "Possibly the same as #38\n\n```text\nR\n```\n")
        #expect(GitHubIssues.comment("R") == "This crash happened again.\n\n```text\nR\n```\n")
    }

    /// `.github/ISSUE_TEMPLATE/crash.md` exists, and its front matter names the crash label.
    @Test func theIssueTemplateParses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: ".github/ISSUE_TEMPLATE/crash.md"), encoding: .utf8)
        let parts = text.components(separatedBy: "---\n")
        #expect(parts.count >= 3 && parts[0].isEmpty)
        var fields: [String: String] = [:]
        for line in parts[1].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        #expect(fields["labels"] == "crash")
        #expect(fields["name"] == "Crash report")
        #expect(fields["about"]?.isEmpty == false)
    }
}
