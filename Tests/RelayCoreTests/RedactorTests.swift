import Testing
@testable import RelayCore

private func redact(_ s: String) -> String { Redactor.redact(s, home: "/Users/me", user: "me") }

@Suite struct RedactorTests {
    @Test func homePathsBecomeTilde() {
        #expect(redact("can't create /Users/me/Library/Application Support/Relay") == "can't create ~/Library/Application Support/Relay")
        #expect(redact("/Users/me") == "~")
        // Another account's home keeps no name either.
        #expect(redact("at /Users/someone/Projects/x.swift") == "at /Users/<user>/Projects/x.swift")
    }

    @Test func theUserNameIsReplacedAsAWordOnly() {
        #expect(redact("owner me refused") == "owner <user> refused")
        // "me" inside a longer word stays.
        #expect(redact("message timed out") == "message timed out")
        #expect(Redactor.redact("signed in as jdoe", home: "/Users/jdoe", user: "jdoe") == "signed in as <user>")
    }

    @Test func urlsAndHostsBecomeHost() {
        #expect(redact("GET https://pond.example.com/asks?x=1 failed") == "GET <host> failed")
        #expect(redact("can't reach pond.example.com") == "can't reach <host>")
        #expect(redact("example-mac.lan refused") == "<host> refused")
        #expect(redact("listener on localhost:47823") == "listener on <host>")
        #expect(redact("example-mac:8443 is down") == "<host> is down")
    }

    @Test func fileNamesAndSymbolsAreNotHosts() {
        #expect(redact("config.json has an error") == "config.json has an error")
        #expect(redact("in SettingsWindow.open") == "in SettingsWindow.open")
        #expect(redact("~/Applications/Hook.app and install.sh") == "~/Applications/Hook.app and install.sh")
        #expect(redact("at 10:42:07 the queue loaded") == "at 10:42:07 the queue loaded")
    }

    @Test func ipAddressesBecomeHost() {
        #expect(redact("connect 192.168.1.20 failed") == "connect <host> failed")
        #expect(redact("from 100.64.0.7:8080") == "from <host>")
        #expect(redact("fe80::1 and ::1") == "<host> and <host>")
        #expect(redact("2001:0db8:85a3:0000:0000:8a2e:0370:7334 down") == "<host> down")
        #expect(redact("2001:db8::8a2e:370:7334 down") == "<host> down")
    }

    @Test func tokensAreRedacted() {
        #expect(redact("Authorization: Bearer abc.def-ghi") == "Authorization: Bearer <redacted>")
        #expect(redact("token ghp_exampleExampleExample1234 leaked") == "token <redacted> leaked")
        #expect(redact("key sk-ant-example0123456789abcdef") == "key <redacted>")
        #expect(redact("seal 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08") == "seal <redacted>")
        #expect(redact("token=abc123 password=hunter2") == "token=<redacted> password=<redacted>")
    }

    @Test func idsAndEmailsDontSurvive() {
        #expect(redact("ask 3F2504E0-4F89-11D3-9A0C-0305E82C3301 gone") == "ask <id> gone")
        #expect(redact("from someone@example.com") == "from <redacted>")
    }

    @Test func aShortSignatureStays() {
        #expect(redact("Crash signature: hook-crash-a3f9c2e17b04") == "Crash signature: hook-crash-a3f9c2e17b04")
    }

    @Test func redactingTwiceChangesNothing() {
        let once = redact("GET https://pond.example.com/x from /Users/me as me, Bearer abc, 10.0.0.1")
        #expect(redact(once) == once)
    }
}

@Suite struct RouteTemplateTests {
    @Test func idsBecomePlaceholders() {
        #expect(RouteTemplate.template("asks/3f2504e0-4f89-11d3-9a0c-0305e82c3301/reply") == "asks/{id}/reply")
        #expect(RouteTemplate.template("/asks/3F2504E0-4F89-11D3-9A0C-0305E82C3301") == "asks/{id}")
        #expect(RouteTemplate.template("asks/42/revisions/3") == "asks/{id}/revisions/{id}")
        #expect(RouteTemplate.template("owner/keys/9f86d081884c7d65") == "owner/keys/{id}")
    }

    @Test func queryAndHostAreDropped() {
        #expect(RouteTemplate.template("asks?status=open&days=7") == "asks")
        #expect(RouteTemplate.template("https://pond.example.com/asks/42/events?after=9") == "asks/{id}/events")
        #expect(RouteTemplate.template("version") == "version")
    }

    @Test func oddSegmentsDontCarryText() {
        #expect(RouteTemplate.template("asks/a title with spaces") == "asks/{id}")
    }
}
