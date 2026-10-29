import Foundation
import Testing
@testable import RelayCore

private func release(_ fields: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: fields)
}

private let page = "https://github.com/xooxoxxo/relay/releases/tag/v0.6.5"

@Suite struct ReleaseVersionTests {
    @Test func parsesWithAndWithoutTheLeadingV() {
        #expect(ReleaseVersion("v0.6.5")?.description == "0.6.5")
        #expect(ReleaseVersion("0.6.5")?.description == "0.6.5")
        #expect(ReleaseVersion("v1.0.0") == ReleaseVersion("1.0.0"))
    }

    @Test func comparesEachPartAsANumber() throws {
        let v = { (s: String) throws -> ReleaseVersion in try #require(ReleaseVersion(s)) }
        #expect(try v("0.6.10") > v("0.6.9"))
        #expect(try v("0.10.0") > v("0.9.99"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try !(v("v0.6.5") > v("0.6.5")))
        #expect(try v("0.6.4") < v("v0.6.5"))
    }

    @Test func preReleasesAndGarbageDoNotParse() {
        for tag in ["v0.6.5-beta.1", "0.6.5-rc1", "0.6.5+build", "0.6", "0.6.5.1", "latest", "", "v",
                    "V0.6.5", "vv0.6.5", "0.06.5", "0.6.x", "0..5", " ", "0.6.5 extra", "١.٢.٣"] {
            #expect(ReleaseVersion(tag) == nil, "\(tag)")
        }
    }
}

@Suite struct LatestReleaseTests {
    @Test func readsTheTagAndThePage() throws {
        let parsed = try #require(LatestRelease.parse(release(
            ["tag_name": "v0.6.5", "html_url": page, "name": "0.6.5", "draft": false, "prerelease": false])))
        #expect(parsed.tag == "v0.6.5")
        #expect(parsed.version.description == "0.6.5")
        #expect(parsed.url.absoluteString == page)
    }

    @Test func rejectsWhatIsNotAFinalRelease() {
        #expect(LatestRelease.parse(release(["tag_name": "v0.7.0-beta", "html_url": page])) == nil)
        #expect(LatestRelease.parse(release(["tag_name": "v0.7.0", "html_url": page, "prerelease": true])) == nil)
        #expect(LatestRelease.parse(release(["tag_name": "v0.7.0", "html_url": page, "draft": true])) == nil)
        #expect(LatestRelease.parse(release(["tag_name": "v0.7.0"])) == nil)
        #expect(LatestRelease.parse(release(["tag_name": "v0.7.0", "html_url": "http://github.com/x"])) == nil)
        #expect(LatestRelease.parse(release(["tag_name": 7, "html_url": page])) == nil)
        #expect(LatestRelease.parse(release(["message": "Not Found"])) == nil)
        #expect(LatestRelease.parse(Data("not json".utf8)) == nil)
        #expect(LatestRelease.parse(Data("[]".utf8)) == nil)
    }
}

@Suite struct UpdateStateTests {
    private let latest = LatestRelease(tag: "v0.6.5", version: ReleaseVersion("0.6.5")!,
                                       url: URL(string: page)!)

    @Test func onlyAStrictlyNewerReleaseIsAvailable() {
        #expect(UpdateState.resolve(current: "0.6.4", latest: latest)
            == .available(version: "0.6.5", tag: "v0.6.5", url: URL(string: page)!))
        #expect(UpdateState.resolve(current: "0.6.5", latest: latest) == UpdateState.none)
        #expect(UpdateState.resolve(current: "0.6.10", latest: latest) == UpdateState.none)
        #expect(UpdateState.resolve(current: "0.6.4", latest: nil) == UpdateState.none)
    }

    @Test func aRunningVersionThatDoesNotParseNeverOffersOne() {
        #expect(UpdateState.resolve(current: "—", latest: latest) == UpdateState.none)
        #expect(UpdateState.resolve(current: "0.6.4-dev", latest: latest) == UpdateState.none)
    }

    @Test func aReplyResolvesToAvailableNoneOrFailed() {
        let ok = release(["tag_name": "v0.6.5", "html_url": page])
        #expect(UpdateState.resolve(current: "0.6.4", reply: .success(ok)).availableVersion == "0.6.5")
        #expect(UpdateState.resolve(current: "0.6.5", reply: .success(ok)) == UpdateState.none)
        #expect(UpdateState.resolve(current: "0.6.4", reply: .success(Data("{}".utf8)))
            == .failed(reason: "GitHub's reply had no release version"))
        #expect(UpdateState.resolve(current: "0.6.4", reply: .failure(UpdateCheckError("offline")))
            == .failed(reason: "offline"))
        #expect(UpdateState.checking.availableVersion == nil)
    }
}

@Suite struct UpdateGateTests {
    @Test func aCleanMainFastForwards() {
        #expect(UpdateGate.check(porcelain: "", branch: "main\n", headTag: nil) == .ok(.fastForward))
        #expect(UpdateGate.check(porcelain: "\n", branch: "main", headTag: "v0.6.4") == .ok(.fastForward))
    }

    @Test func aCleanDetachedReleaseTagChecksOut() {
        #expect(UpdateGate.check(porcelain: "", branch: "", headTag: "v0.6.4\n") == .ok(.checkout))
    }

    @Test func changesRefuseWithTheCount() {
        #expect(UpdateGate.check(porcelain: " M Sources/Relay/AppDelegate.swift\n", branch: "main", headTag: nil)
            == .refused("The Hook checkout has changes that aren't committed (1 file has changed). Commit or stash them, then try again."))
        #expect(UpdateGate.check(porcelain: " M a\n?? b\n", branch: "main", headTag: nil)
            == .refused("The Hook checkout has changes that aren't committed (2 files have changed). Commit or stash them, then try again."))
    }

    @Test func anotherBranchOrADetachedNonReleaseRefuses() {
        #expect(UpdateGate.check(porcelain: "", branch: "feat/x", headTag: nil)
            == .refused("The Hook checkout is on the branch “feat/x”, not main. Switch it to main, then try again."))
        #expect(UpdateGate.check(porcelain: "", branch: "", headTag: nil)
            == .refused("The Hook checkout isn't on a branch or a release tag. Switch it to main, then try again."))
        #expect(UpdateGate.check(porcelain: "", branch: "", headTag: "v0.7.0-beta") != .ok(.checkout))
        #expect(UpdateGate.check(porcelain: "", branch: "", headTag: "0.6.4") != .ok(.checkout))
    }

    @Test func theOriginMustBeTheRepoUnderEitherName() {
        for name in ["relay", "hook"] {
            #expect(UpdateGate.isRepoOrigin("https://github.com/xooxoxxo/\(name).git\n"))
            #expect(UpdateGate.isRepoOrigin("https://github.com/xooxoxxo/\(name)"))
            #expect(UpdateGate.isRepoOrigin("https://github.com/xooxoxxo/\(name)/"))
            #expect(UpdateGate.isRepoOrigin("git@github.com:xooxoxxo/\(name).git"))
            #expect(UpdateGate.isRepoOrigin("ssh://git@github.com/xooxoxxo/\(name).git"))
            #expect(UpdateGate.isRepoOrigin("HTTPS://GitHub.com/xooxoxxo/\(name).git"))
            #expect(!UpdateGate.isRepoOrigin("https://github.com/someone/\(name).git"))
            #expect(!UpdateGate.isRepoOrigin("https://github.com/xooxoxxo/\(name)-fork.git"))
            #expect(!UpdateGate.isRepoOrigin("https://gitlab.com/xooxoxxo/\(name).git"))
        }
        #expect(!UpdateGate.isRepoOrigin("https://github.com/xooxoxxo/fish.git"))
        #expect(!UpdateGate.isRepoOrigin(""))
    }

    @Test func theReleaseCheckStaysOnTheOldRepoPath() {
        #expect(UpdateGate.latestReleaseAPI == "https://api.github.com/repos/xooxoxxo/relay/releases/latest")
    }
}

@Suite struct UpdatePlanTests {
    private func plan(_ mode: UpdateGate.Mode, repo: String = "/Users/me/relay") -> UpdatePlan {
        UpdatePlan(repoPath: repo, tag: "v0.6.5", mode: mode, current: "0.6.4",
                   appPath: "/Users/me/Applications/Hook.app", logPath: "/Users/me/Library/Logs/Relay/update.log",
                   scriptPath: "/tmp/relay-update.sh", plistPath: "/tmp/relay-update.plist", home: "/Users/me")
    }

    @Test func theScriptFetchesMovesAndInstallsInOrder() {
        let lines = plan(.fastForward).script.split(separator: "\n").map(String.init)
        #expect(lines.first == "#!/bin/sh")
        let steps = lines.filter { !$0.hasPrefix(" ") && $0.contains("|| fail") }
        #expect(steps == [
            "cd '/Users/me/relay' || fail \"couldn't open the checkout\"",
            "/usr/bin/git fetch origin --tags || fail \"git fetch origin --tags\"",
            "/usr/bin/git merge --ff-only 'v0.6.5' || fail 'git merge --ff-only v0.6.5'",
            "./scripts/install.sh || fail \"./scripts/install.sh\"",
        ])
        #expect(lines.last == "finish")
    }

    @Test func aDetachedCheckoutChecksOutTheTag() {
        #expect(plan(.checkout).moveCommand == "/usr/bin/git checkout --quiet 'v0.6.5'")
        #expect(plan(.checkout).script.contains("/usr/bin/git checkout --quiet 'v0.6.5' || fail 'git checkout v0.6.5'"))
        #expect(!plan(.checkout).script.contains("merge"))
    }

    @Test func aFailureRestartsRelayIfItIsNotRunningAndTheJobRemovesItself() {
        let script = plan(.fastForward).script
        #expect(script.contains("/usr/bin/pgrep -u \"$(/usr/bin/id -u)\" -x Hook >/dev/null 2>&1 || /usr/bin/open -g -a '/Users/me/Applications/Hook.app'"))
        #expect(script.contains("rm -f '/tmp/relay-update.plist' '/tmp/relay-update.sh'"))
        #expect(script.contains("exec /bin/launchctl remove 'io.github.xooxoxxo.relay.update'"))
        #expect(script.contains("export HOME='/Users/me'"))
    }

    @Test func pathsAreQuotedForTheShell() {
        let script = plan(.fastForward, repo: "/Users/me/it's $HOME").script
        #expect(script.contains("cd '/Users/me/it'\\''s $HOME' || fail"))
        #expect(Shell.quote("a'b") == "'a'\\''b'")
    }

    @Test func theJobRunsOnceOutsideRelayAndLogsBothStreams() {
        let job = plan(.fastForward).jobPlist
        #expect(job["Label"] as? String == "io.github.xooxoxxo.relay.update")
        #expect(job["ProgramArguments"] as? [String] == ["/bin/sh", "/tmp/relay-update.sh"])
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["KeepAlive"] as? Bool == false)
        #expect(job["AbandonProcessGroup"] as? Bool == true)
        #expect(job["StandardOutPath"] as? String == "/Users/me/Library/Logs/Relay/update.log")
        #expect(job["StandardErrorPath"] as? String == "/Users/me/Library/Logs/Relay/update.log")
        #expect(plan(.fastForward).launchCommands(uid: 501) == [
            ["/bin/launchctl", "bootout", "gui/501/io.github.xooxoxxo.relay.update"],
            ["/bin/launchctl", "bootstrap", "gui/501", "/tmp/relay-update.plist"],
        ])
    }

    @Test func theUpdatingNoticeNamesTheLogBehindItsHelp() {
        let notice = PanelNotice.updating(version: "0.6.5", logPath: "~/Library/Logs/Relay/update.log")
        #expect(notice.text == "Updating to 0.6.5. Hook restarts in about 2 minutes.")
        #expect(notice.kind == .info)
        #expect(notice.actionTitle == nil)
        #expect(notice.help?.hasSuffix("~/Library/Logs/Relay/update.log") == true)
        #expect(PanelNotice.settingsReloaded.help == nil)
    }
}
