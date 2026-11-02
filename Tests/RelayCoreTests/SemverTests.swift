import Foundation
import Testing
@testable import RelayCore

/// Fixtures/semver-vectors.json: the same file clients/test_relay_semver.py reads.
private func loadSemverCases() throws -> [JSONValue] {
    let url = try #require(Bundle.module.url(
        forResource: "semver-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONValue.parse(Data(contentsOf: url))
    guard root["version"] == .int(1), case .array(let cases)? = root["cases"] else {
        Issue.record("semver-vectors.json has no version 1 cases")
        return []
    }
    return cases
}

private func cases(_ kind: String) throws -> [JSONValue] {
    try loadSemverCases().filter { $0["kind"]?.stringValue == kind }
}

private func version(_ text: String) throws -> SemVer {
    try #require(SemVer(strict: text), "\(text) should parse")
}

@Suite struct SemverTests {
    @Test func theFileIsWhole() throws {
        let all = try loadSemverCases()
        #expect(all.count >= 50)
        for kind in ["version", "order", "range", "pond"] {
            #expect(try !cases(kind).isEmpty, "no \(kind) cases")
        }
    }

    @Test func versionsParseStrictly() throws {
        for item in try cases("version") {
            let input = try #require(item["input"]?.stringValue)
            let parsed = SemVer(strict: input)
            guard item["valid"] == .bool(true) else {
                #expect(parsed == nil, "\(input) should be refused")
                continue
            }
            guard case .array(let parts)? = item["parts"], parts.count == 4,
                  case .int(let major) = parts[0], case .int(let minor) = parts[1], case .int(let patch) = parts[2],
                  case .array(let pre) = parts[3] else {
                Issue.record("malformed parts for \(input)")
                continue
            }
            #expect(parsed == SemVer(major: major, minor: minor, patch: patch, prerelease: pre.compactMap(\.stringValue)),
                    "\(input)")
        }
    }

    @Test func versionsOrderBySemverPrecedence() throws {
        for item in try cases("order") {
            let a = try version(try #require(item["a"]?.stringValue))
            let b = try version(try #require(item["b"]?.stringValue))
            guard case .int(let cmp)? = item["cmp"] else { Issue.record("no cmp"); continue }
            #expect(SemVer.compare(a, b) == cmp, "\(a) vs \(b)")
            #expect(SemVer.compare(b, a) == -cmp, "\(b) vs \(a)")
            #expect((a < b) == (cmp < 0), "\(a) < \(b)")
            #expect((a > b) == (cmp > 0), "\(a) > \(b)")
            #expect((a == b) == (cmp == 0), "\(a) == \(b)")
        }
    }

    @Test func rangesContainAndFit() throws {
        for item in try cases("range") {
            let text = try #require(item["range"]?.stringValue)
            guard item["valid"] == .bool(true) else {
                #expect(throws: SemverRangeError.self, "\(text) should be refused") { try SemverRange(text) }
                continue
            }
            let range = try SemverRange(text)
            guard case .array(let checks)? = item["checks"], !checks.isEmpty else {
                Issue.record("no checks for \(text)")
                continue
            }
            for check in checks {
                let v = try version(try #require(check["version"]?.stringValue))
                #expect(range.contains(v) == (check["contains"] == .bool(true)), "\(text) contains \(v)")
                #expect(range.fit(v).rawValue == check["fit"]?.stringValue, "\(text) fit \(v)")
            }
        }
    }

    @Test func pondVersionsFallBackToTheProtocol() throws {
        for item in try cases("pond") {
            let info = item["info"]
            var text: String?
            var level: Int?
            if case .object? = info {
                text = info?["version"]?.stringValue
                if case .int(let n)? = info?["protocol"] { level = n }
            }
            let pond = PondVersion.from(version: text, protocol: level)
            let effective = try version(try #require(item["effective"]?.stringValue))
            #expect(pond.effective == effective, "\(String(describing: info))")
            switch item["legacy"] {
            case .int(let n)?: #expect(pond == .legacy(protocol: n), "\(String(describing: info))")
            default: #expect(pond == .semver(effective), "\(String(describing: info))")
            }
        }
    }

    @Test func aBadRangeNamesTheBadPart() {
        #expect(throws: SemverRangeError.invalid("^1.1")) { try SemverRange(">=1.0.0 ^1.1") }
        #expect(throws: SemverRangeError.invalid("empty")) { try SemverRange("") }
    }

    @Test func buildMetadataIsIgnored() throws {
        #expect(try version("1.0.0+a") == version("1.0.0+b"))
        #expect(try version("1.2.0-rc.1+b.2").description == "1.2.0-rc.1")
        #expect(try version("1.1.0").description == "1.1.0")
    }

    @Test func thePondHookNeedsParses() throws {
        #expect(PondCompat.required == "^1.1.0")
        #expect(PondCompat.localVersion == "1.0.0")
        #expect(PondCompat.range == (try SemverRange("^1.1.0")))
        #expect(SemVer(strict: PondCompat.localVersion) != nil)
        #expect(PondCompat.range.description == "^1.1.0")
    }

    @Test func aPondDisplaysItsVersionOrItsProtocol() throws {
        #expect(PondVersion.semver(try version("1.1.0")).display == "1.1.0")
        #expect(PondVersion.legacy(protocol: 4).display == "protocol 4")
        #expect(PondVersion.legacy(protocol: 4).effective == (try version("1.0.0")))
        #expect(PondVersion.legacy(protocol: 7).effective == (try version("1.0.0")))
        #expect(PondVersion.legacy(protocol: 3).effective == (try version("0.3.0")))
        #expect(PondVersion.from(version: nil, protocol: 0) == .legacy(protocol: 1))
    }
}
