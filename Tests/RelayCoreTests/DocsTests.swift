import Foundation
import Testing
@testable import RelayCore

/// The repo's docs say what the code does: every config key is documented, the privacy doc
/// states the log's and the report's real limits, and every relative link and anchor resolves.
@Suite struct DocsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// `onboarding` is the installer's one-shot flag, not a setting.
    private static let undocumentedKeys: Set<String> = ["onboarding"]

    @Test func everyConfigKeyHasARowInConfigurationMd() throws {
        let doc = try Self.read("docs/configuration.md")
        let rows = Set(Self.matches(#"(?m)^\| `([A-Za-z]+)` \|"#, in: doc))
        let keys = Set(RelayConfig.CodingKeys.allCases.map(\.rawValue)).subtracting(Self.undocumentedKeys)
        #expect(keys.subtracting(rows).sorted() == [], "keys without a row in docs/configuration.md")
        #expect(rows.subtracting(keys).sorted() == [], "rows for keys Hook doesn't read")
    }

    @Test func thePrivacyDocStatesTheRealLimits() throws {
        let doc = try Self.read("docs/privacy.md")
        for fact in [
            "~/Library/Logs/Hook/hook.log",
            "hook.1.log",
            "\(RollingLog.defaultLimit / 1024) KB",
            "last \(CrashReportText.logLines) log lines",
            CrashReportText.signatureLine("<signature>"),
            "`crashReports`",
            "`crashReportTarget`",
            "run-state.json",
        ] {
            #expect(doc.contains(fact), "docs/privacy.md doesn't say \(fact)")
        }
        let limit = GitHubIssues.urlLimit.formatted(.number.locale(Locale(identifier: "en_US")))
        #expect(doc.contains("\(limit) characters"))
        #expect(try Self.read("SECURITY.md").contains("(docs/privacy.md)"))
    }

    @Test func everyRelativeLinkAndAnchorResolves() throws {
        let docs = try FileManager.default.contentsOfDirectory(atPath: Self.root.appending(path: "docs").path)
            .filter { $0.hasSuffix(".md") }.map { "docs/" + $0 }
        var broken: [String] = []
        for file in ["README.md", "SECURITY.md", "CONTRIBUTING.md", "CHANGELOG.md"] + docs.sorted() {
            let text = try Self.read(file)
            for target in Self.matches(#"\]\(([^)\s]+)\)"#, in: text) where target.range(of: "^[a-z]+:", options: .regularExpression) == nil {
                let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let dir = (file as NSString).deletingLastPathComponent
                let path = parts[0].isEmpty ? file : ((dir as NSString).appendingPathComponent(parts[0]) as NSString).standardizingPath
                guard FileManager.default.fileExists(atPath: Self.root.appending(path: path).path) else {
                    broken.append("\(file): \(target)")
                    continue
                }
                if parts.count == 2, path.hasSuffix(".md"), !Self.anchors(try Self.read(path)).contains(parts[1]) {
                    broken.append("\(file): \(target)")
                }
            }
        }
        #expect(broken == [])
    }

    /// GitHub's heading anchors (lowercase, punctuation dropped, spaces as hyphens), plus
    /// explicit `<a id="…">` anchors. Headings inside code fences don't count.
    static func anchors(_ text: String) -> Set<String> {
        var out = Set(matches(#"<a id="([^"]+)">"#, in: text))
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenced.toggle() }
            guard !fenced, let heading = matches(#"^#+ (.*)$"#, in: line).first else { continue }
            let plain = heading.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            out.insert(plain.replacingOccurrences(of: " ", with: "-"))
        }
        return out
    }

    @Test func anchorsFollowGitHub() {
        #expect(DocsTests.anchors("## Settings › Privacy\n") == ["settings--privacy"])
        #expect(DocsTests.anchors("## What a report contains\n```\n# not a heading\n```\n") == ["what-a-report-contains"])
        #expect(DocsTests.anchors(#"<a id="old-name"></a>"#) == ["old-name"])
    }

    /// The first capture group of every match.
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
