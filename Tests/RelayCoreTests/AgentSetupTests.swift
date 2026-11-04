import Foundation
import Testing
@testable import RelayCore

@Suite struct AgentSetupTests {
    @Test func theDonationButtonNeedsAnHTTPSLink() {
        #expect(ConnectInfo.donationLink() == URL(string: "https://ko-fi.com/xo-vision"))   // the shipped link
        #expect(ConnectInfo.donationLink("") == nil)
        #expect(ConnectInfo.donationLink("http://example.com/support") == nil)
        #expect(ConnectInfo.donationLink(" https://example.com/support ")?.host() == "example.com")
    }
}

@Suite struct LoginShellTests {
    @Test func itRunsACommandAndKeepsTheOutput() async {
        let outcome = await LoginShell.run("echo hello; echo oops >&2", shell: "/bin/sh", timeout: 10)
        #expect(outcome.ok && outcome.output == "hello\noops")
    }

    @Test func aFailureKeepsItsStatusAndOutput() async {
        let outcome = await LoginShell.run("echo first; echo 'it broke'; exit 3", shell: "/bin/sh", timeout: 10)
        #expect(!outcome.ok && outcome.status == 3 && !outcome.timedOut)
        #expect(outcome.output == "first\nit broke")
    }

    /// How IntegrationsRunner keeps the JSON apart from what a login profile prints.
    @Test func redirectedOutputLandsInItsFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appending(path: "out").path, err = folder.appending(path: "err").path
        let outcome = await LoginShell.run("echo profile noise; { echo '{}'; echo oops >&2; } >" + Shell.quote(out)
                                           + " 2>" + Shell.quote(err), shell: "/bin/sh", timeout: 10)
        #expect(outcome.ok && outcome.output == "profile noise")
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "{}\n")
        #expect(try String(contentsOfFile: err, encoding: .utf8) == "oops\n")
    }

    @Test func aHungCommandTimesOut() async {
        let start = Date()
        let outcome = await LoginShell.run("sleep 20", shell: "/bin/sh", timeout: 0.5)
        #expect(outcome.timedOut && !outcome.ok)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// bash 3.2 runs `sleep` as a child (no exec of the last command), so stopping only the
    /// shell would leave sleep holding the pipe. The whole group is stopped instead.
    @Test func aTimeoutStopsWhatTheShellStarted() async throws {
        let start = Date()
        let outcome = await LoginShell.run("sleep 20 & echo $!; wait; true", shell: "/bin/bash", timeout: 0.5)
        #expect(outcome.timedOut && !outcome.ok)
        #expect(Date().timeIntervalSince(start) < 15)  // well under the 20 s sleep; CI runners are slow
        let sleeper = try #require(pid_t(outcome.output))
        var gone = false
        for _ in 0..<40 where !gone {
            gone = kill(sleeper, 0) == -1 && errno == ESRCH
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone)
    }

    @Test func aChainedCommandUnderBashTimesOut() async {
        let start = Date()
        let outcome = await LoginShell.run("sleep 20; true", shell: "/bin/bash", timeout: 0.5)
        #expect(outcome.timedOut && !outcome.ok)
        #expect(Date().timeIntervalSince(start) < 15)  // well under the 20 s sleep; CI runners are slow
    }

    /// Something left behind that keeps the pipe open doesn't hold the result back.
    @Test func aLeftoverHoldingThePipeDoesntBlock() async {
        let start = Date()
        let outcome = await LoginShell.run("(sleep 20 &); echo x", shell: "/bin/sh", timeout: 0.5)
        #expect(outcome.ok && outcome.output == "x")
        #expect(Date().timeIntervalSince(start) < 15)  // well under the 20 s sleep; CI runners are slow
    }

    @Test func aMissingShellFails() async {
        let outcome = await LoginShell.run("true", shell: "/nonexistent/shell", timeout: 5)
        #expect(!outcome.ok && outcome.status == -1)
    }

    @Test func theShellIsTheUsersWhenAbsolute() {
        #expect(LoginShell.shell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(LoginShell.shell(environment: ["SHELL": "bash"]) == "/bin/zsh")
        #expect(LoginShell.shell(environment: [:]) == "/bin/zsh")
    }
}
