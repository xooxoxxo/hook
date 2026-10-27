import Foundation
import Testing
@testable import RelayCore

private let session = "5f633ed3-a328-412b-bf54-5b1e0c16a093"
private let script = #"cd -- "$1" && exec claude --resume "$2""#

private func target(cwd: String = "/work/acme", session: String = session) throws -> ResumeTarget {
    try #require(ResumeTarget(AskOrigin(from: Origin(session: session, host: "build-mac", cwd: cwd))))
}

private func steps(_ kind: TerminalKind, cwd: String = "/work/acme", shell: String? = "/bin/zsh",
                   ghostty: String? = nil) throws -> [LaunchStep] {
    TerminalLauncher.plan(kind, target: try target(cwd: cwd), shell: shell, ghosttyVersion: ghostty).steps
}

private let shellTail = ["/bin/zsh", "-lc", script, "hook-resume", "/work/acme", session]

@Suite struct TerminalLauncherTests {
    @Test func terminalAndITermOpenAPrivateCommandFile() throws {
        let body = """
        #!/bin/sh
        rm -f -- "$0"
        cd -- '/work/acme' || exit 1
        exec claude --resume '\(session)'

        """
        #expect(try steps(.terminal) == [.commandFile(body: body, bundleID: "com.apple.Terminal")])
        #expect(try steps(.iterm) == [.commandFile(body: body, bundleID: "com.googlecode.iterm2")])
    }

    @Test func commandFileQuotesAnApostropheInThePath() throws {
        let body = TerminalLauncher.commandFileBody(try target(cwd: "/work/it's $HOME `x`"))
        #expect(body.contains(#"cd -- '/work/it'\''s $HOME `x`' || exit 1"#))
    }

    @Test func ghosttyFromOnePointThreeUsesAppleScriptWithArgumentsThenFallsBack() throws {
        let plan = try steps(.ghostty, ghostty: "1.3.1")
        #expect(plan == [
            .appleScript(source: TerminalLauncher.ghosttyScript, arguments: ["/work/acme", session]),
            .openNew(bundleID: "com.mitchellh.ghostty", arguments: ["--working-directory=/work/acme", "-e"] + shellTail),
        ])
        // The values never appear in the script source.
        #expect(!TerminalLauncher.ghosttyScript.contains("/work/acme"))
        #expect(!TerminalLauncher.ghosttyScript.contains(session))
        #expect(TerminalLauncher.ghosttyScript.contains("new window with configuration"))
        #expect(TerminalLauncher.ghosttyScript.contains("initial working directory"))
        #expect(TerminalLauncher.ghosttyScript.contains("initial input"))
    }

    @Test func olderOrUnknownGhosttyOpensANewInstance() throws {
        let openNew = LaunchStep.openNew(bundleID: "com.mitchellh.ghostty",
                                         arguments: ["--working-directory=/work/acme", "-e"] + shellTail)
        #expect(try steps(.ghostty, ghostty: "1.2.3") == [openNew])
        #expect(try steps(.ghostty, ghostty: nil) == [openNew])
    }

    @Test(arguments: [("1.3", true), ("1.3.0", true), ("1.10.2", true), ("2.0", true), ("1.2.9", false),
                      ("0.9", false), ("tip", false), ("1.3.0-dev", true)])
    func ghosttyVersionGate(_ version: String, _ expected: Bool) {
        #expect(TerminalLauncher.supportsGhosttyScripting(version) == expected)
    }

    @Test func kittyOpensANewInstanceInTheFolder() throws {
        #expect(try steps(.kitty) == [
            .openNew(bundleID: "net.kovidgoyal.kitty", arguments: ["--directory", "/work/acme"] + shellTail),
        ])
    }

    @Test func weztermStartsDetachedWithCwd() throws {
        #expect(try steps(.wezterm) == [
            .process(bundleID: "com.github.wez.wezterm", executable: "Contents/MacOS/wezterm",
                     arguments: ["start", "--cwd", "/work/acme", "--"] + shellTail, waits: false),
        ])
    }

    @Test func alacrittyTriesTheRunningInstanceThenANewOne() throws {
        let tail = ["--working-directory", "/work/acme", "-e"] + shellTail
        #expect(try steps(.alacritty) == [
            .process(bundleID: "org.alacritty", executable: "Contents/MacOS/alacritty",
                     arguments: ["msg", "create-window"] + tail, waits: true),
            .openNew(bundleID: "org.alacritty", arguments: tail),
        ])
    }

    @Test func warpWritesOneTabConfigAndOpensIt() throws {
        let plan = try steps(.warp, cwd: #"/work/a "quoted" \ dir"#)
        let contents = """
        name = "Hook resume"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "/work/a \\"quoted\\" \\\\ dir"
        commands = ["claude --resume \(session)"]

        """
        #expect(plan == [
            .fileThenURL(file: ".warp/tab_configs/hook-resume.toml", contents: contents,
                         url: try #require(URL(string: "warp://tab_config/hook-resume?new_window=true"))),
        ])
    }

    @Test func pathsWithSpacesStayOneArgument() throws {
        let plan = try steps(.kitty, cwd: "/work/My Projects/site; rm -rf ~")
        guard case let .openNew(_, arguments) = try #require(plan.first) else {
            Issue.record("expected openNew")
            return
        }
        #expect(arguments[1] == "/work/My Projects/site; rm -rf ~")
        #expect(arguments.last == session)
        #expect(arguments[arguments.count - 2] == "/work/My Projects/site; rm -rf ~")
        #expect(arguments[4] == script)
    }

    @Test func loginShellIsTheUsersWhenPosixElseZsh() throws {
        #expect(TerminalLauncher.shell("/bin/bash") == "/bin/bash")
        #expect(TerminalLauncher.shell("/opt/homebrew/bin/zsh") == "/opt/homebrew/bin/zsh")
        #expect(TerminalLauncher.shell("/opt/homebrew/bin/fish") == "/bin/zsh")
        #expect(TerminalLauncher.shell("zsh") == "/bin/zsh")
        #expect(TerminalLauncher.shell(nil) == "/bin/zsh")
        #expect(TerminalLauncher.shellCommand(try target(), shell: "/bin/bash").prefix(2) == ["/bin/bash", "-lc"])
    }

    @Test func noTargetWithoutAResumeCommand() {
        #expect(ResumeTarget(nil) == nil)
        #expect(ResumeTarget(AskOrigin(from: Origin(session: session, host: "h", cwd: "relative/path"))) == nil)
        #expect(ResumeTarget(AskOrigin(from: Origin(session: session, host: "h", cwd: "/a\nb"))) == nil)
        #expect(ResumeTarget(AskOrigin(from: Origin(session: "bad id!", host: "h", cwd: "/a"))) == nil)
        #expect(ResumeTarget(AskOrigin(from: Origin(session: nil, host: "h", cwd: "/a"))) == nil)
    }

    @Test func kindsByBundleIDAndTheAutomaticSetting() {
        #expect(TerminalKind.resolve("automatic") == .terminal)
        #expect(TerminalKind.resolve("") == .terminal)
        #expect(TerminalKind.resolve("com.example.unknown") == .terminal)
        #expect(TerminalKind.resolve("com.mitchellh.ghostty") == .ghostty)
        #expect(TerminalKind.resolve(" net.kovidgoyal.kitty ") == .kitty)
        for kind in TerminalKind.allCases { #expect(TerminalKind(bundleID: kind.bundleID) == kind) }
    }
}

@Suite struct ResumeAvailabilityTests {
    private func origin(host: String?, cwd: String? = "/work/acme", session: String? = session) -> AskOrigin? {
        AskOrigin(from: Origin(session: session, host: host, cwd: cwd))
    }

    @Test func availableOnlyOnThisMac() {
        #expect(ResumeAvailability.of(origin(host: "build-mac"), localHost: "build-mac") == .available)
        #expect(ResumeAvailability.of(origin(host: "Build-Mac.local"), localHost: "build-mac") == .available)
        #expect(ResumeAvailability.of(origin(host: "other-mac"), localHost: "build-mac")
                == .unavailable(reason: "Session is on other-mac"))
        #expect(ResumeAvailability.of(origin(host: "other-mac"), localHost: nil)
                == .unavailable(reason: "Session is on other-mac"))
        #expect(ResumeAvailability.of(origin(host: nil), localHost: "build-mac")
                == .unavailable(reason: "Session is on an unknown Mac"))
    }

    @Test func noneWithoutAResumeCommand() {
        #expect(ResumeAvailability.of(nil, localHost: "build-mac") == .none)
        #expect(ResumeAvailability.of(origin(host: "build-mac", cwd: nil), localHost: "build-mac") == .none)
        #expect(ResumeAvailability.of(origin(host: "build-mac", session: nil), localHost: "build-mac") == .none)
    }

    @Test func theHostInTheReasonIsSanitized() {
        #expect(ResumeAvailability.of(origin(host: "ev\u{202E}il"), localHost: "build-mac")
                == .unavailable(reason: "Session is on ev⟨U+202E⟩il"))
    }

    @Test func hostNamesCompareOnTheFirstLabel() {
        #expect(HostName.same("build-mac", "BUILD-MAC.lan"))
        #expect(!HostName.same("build-mac", "build-mac-2"))
        #expect(!HostName.same("", ""))
        #expect(!HostName.same(".local", ".local"))
    }
}

@Suite struct TerminalChoiceTests {
    @Test func automaticThenInstalledInOrder() {
        let options = TerminalChoice.options(installed: [.kitty, .terminal, .ghostty], current: "automatic")
        #expect(options.map(\.id) == ["automatic", "com.apple.Terminal", "com.mitchellh.ghostty", "net.kovidgoyal.kitty"])
        #expect(options.map(\.title) == ["Automatic (Terminal)", "Terminal", "Ghostty", "kitty"])
    }

    @Test func aSavedTerminalThatIsGoneStaysListed() {
        let options = TerminalChoice.options(installed: [.terminal], current: "org.alacritty")
        #expect(options.last == TerminalChoice(id: "org.alacritty", title: "Alacritty (not installed)"))
        let unknown = TerminalChoice.options(installed: [], current: "com.example.term")
        #expect(unknown.last == TerminalChoice(id: "com.example.term", title: "com.example.term (not installed)"))
    }
}

@Suite struct ResumeNoticeTests {
    @Test func resumeFailedIsAnErrorWithoutAnAction() {
        let notice = PanelNotice.resumeFailed(reason: "The session's folder no longer exists.")
        #expect(notice.kind == .error)
        #expect(notice.actionTitle == nil)
        #expect(notice.showsOnQueue)
        #expect(notice.text == "Couldn't open the terminal, so the resume command is on the clipboard. The session's folder no longer exists.")
    }
}
