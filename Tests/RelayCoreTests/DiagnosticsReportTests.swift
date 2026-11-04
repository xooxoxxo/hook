import Foundation
import Testing
@testable import RelayCore

@Suite struct DiagnosticsReportTests {
    private let launchctl = """
        gui/501/io.github.xooxoxxo.relay = {
        	active count = 0
        	path = /Users/me/Library/LaunchAgents/io.github.xooxoxxo.relay.plist
        	state = not running
        	program = /usr/bin/open
        	runs = 3
        	last exit code = 0
        }
        """

    private func parts() -> DiagnosticsReport.Parts {
        DiagnosticsReport.Parts(
            hookVersion: "0.14.0", macOS: "27.0.1", cpu: "arm64",
            copies: ["/Users/me/Applications/Hook.app", "/Users/me/src/hook/build/Hook.app"],
            launchAgent: launchctl,
            runState: #"{"clean":true,"cause":{"kind":"signal","detail":"TERM","pid":1,"process":"launchd"},"pid":812}"#,
            launches: nil,
            hookLog: (0..<400).map { "2026-11-04T10:00:00Z line \($0)" },
            updateLog: ["update: 2026-11-03 Hook 0.13.0 -> v0.14.0 in /Users/me/src/hook"],
            crashFiles: ["Hook-2026-11-04-100000.ips  2026-11-04 10:00  48 KB"],
            systemLog: ["2026-11-04 10:00:01 loginwindow: appDeath Hook pid 812 on Sams-MacBook-Pro.local",
                        "2026-11-04 10:00:01 runningboardd: [app<application.io.github.xooxoxxo.relay>:812] Sams-MacBook-Pro termination"])
    }

    @Test func theFileHoldsEachPartRedacted() {
        let text = DiagnosticsReport.text(parts(), now: Date(timeIntervalSince1970: 1_793_700_000), home: "/Users/me",
                                          user: "me", hosts: ["Sams-MacBook-Pro", "Sam's MacBook Pro"])
        #expect(text.hasPrefix("Hook diagnostics\nSaved     2026-11-03T10:00:00Z\nHook      0.14.0 (arm64) · macOS 27.0.1\n"))
        #expect(text.contains("== Copies of Hook (LaunchServices and Spotlight)\n~/Applications/Hook.app\n~/src/hook/build/Hook.app\n"))
        #expect(text.contains("== LaunchAgent (launchctl print: state, last exit code, runs)\nstate = not running\nruns = 3\nlast exit code = 0\n"))
        #expect(!text.contains("program = /usr/bin/open"))
        #expect(text.contains("== launches.json\n(missing)\n"))
        #expect(text.contains("line 100\n"))
        #expect(!text.contains("line 99\n"))
        #expect(text.contains("update: 2026-11-03 Hook 0.13.0 -> v0.14.0 in ~/src/hook"))
        #expect(text.contains("appDeath Hook pid 812 on <host>"))
        #expect(text.contains("<host> termination"))
        #expect(!text.contains("Sams"))
        #expect(!text.contains("/Users/me"))
    }

    @Test func launchctlFailingSaysWhy() {
        var p = parts()
        p.launchAgent = "Bad request.\nCould not find service in domain for user gui: 501"
        let text = DiagnosticsReport.text(p, now: Date(), home: "/Users/me", user: "me", hosts: [])
        #expect(text.contains("== LaunchAgent (launchctl print: state, last exit code, runs)\nBad request. Could not find service"))
    }

    @Test func theFileNameAndPredicate() {
        #expect(DiagnosticsReport.fileName(now: Date(timeIntervalSince1970: 1_793_700_000), timeZone: TimeZone(identifier: "UTC")!)
            == "hook-diagnostics-2026-11-03-1000.txt")
        #expect(DiagnosticsReport.systemLogPredicate
            == #"(process == "runningboardd" OR process == "launchd" OR process == "loginwindow") AND eventMessage CONTAINS[c] "Hook""#)
    }

    @Test func theHostNameGoesInEitherForm() {
        #expect(DiagnosticsReport.redact("a Mac-Mini.local b mac-mini c", home: "/Users/me", user: "me",
                                         hosts: ["Mac-Mini.local"]) == "a <host> b <host> c")
        #expect(DiagnosticsReport.redact("on Sam's MacBook Pro now", home: "/Users/me", user: "me",
                                         hosts: ["Sams-MacBook-Pro", "Sam's MacBook Pro"]) == "on <host> now")
        #expect(DiagnosticsReport.redact("x", home: "/Users/me", user: "me", hosts: [""]) == "x")
    }

    @Test func theRowSaysWhereItIs() {
        #expect(DiagnosticsState.idle.text == "For an issue report")
        #expect(DiagnosticsState.collecting.text == "Collecting…")
        #expect(DiagnosticsState.collecting.collecting)
        #expect(DiagnosticsState.saved("hook-diagnostics-2026-11-04-1530.txt").text
            == "Saved hook-diagnostics-2026-11-04-1530.txt")
        #expect(DiagnosticsState.failed("disk full").text == "Couldn't save: disk full")
        #expect(PrivacyLine().diagnostics == .idle)
    }
}
