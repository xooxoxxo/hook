import Foundation
import Testing
@testable import RelayCore
@testable import RelayMacCore

@Suite struct InstallKindTests {
    private func detect(_ path: String?, _ files: Set<String>) -> InstallKind {
        InstallKind.detect(repoPath: path, fileExists: { files.contains($0) })
    }

    @Test func aReleaseDownloadIsTheFolderHoldingCurrent() {
        let current = "/Users/me/.local/share/hook/current"
        #expect(detect(current, [current + "/VERSION", current + "/scripts/get.sh"])
            == .release(home: "/Users/me/.local/share/hook"))
        #expect(detect(current + "/", [current + "/VERSION", current + "/scripts/get.sh"])
            == .release(home: "/Users/me/.local/share/hook"))
    }

    @Test func aCloneIsACheckoutEvenWithAVersionFile() {
        let repo = "/Users/me/src/hook"
        #expect(detect(repo, [repo + "/.git"]) == .checkout(repo: repo))
        #expect(detect(repo, [repo + "/.git", repo + "/VERSION", repo + "/scripts/get.sh"]) == .checkout(repo: repo))
    }

    @Test func anythingElseIsUnknown() {
        #expect(detect(nil, []) == .unknown)
        #expect(detect("  ", []) == .unknown)
        #expect(detect("relative/hook", ["relative/hook/.git"]) == .unknown)
        #expect(detect("/Users/me/hook", ["/Users/me/hook/VERSION"]) == .unknown)
        #expect(detect("/Users/me/hook", []) == .unknown)
    }

    @Test func theSettingsLineNamesTheModeAndWhatAnUpdateDoes() {
        let release = InstallKind.release(home: "/Users/me/.local/share/hook").line(home: "/Users/me")
        #expect(release.mode == "Release download")
        #expect(release.detail.contains("SHA256SUMS"))
        #expect(release.detail.contains("~/.local/share/hook/current"))
        let checkout = InstallKind.checkout(repo: "/Users/me/src/hook").line(home: "/Users/me")
        #expect(checkout.mode == "Developer checkout")
        #expect(checkout.detail.contains("~/src/hook"))
        #expect(checkout.detail.contains("rebuild"))
        #expect(InstallKind.unknown.line(home: "/Users/me").detail.contains("get.sh"))
    }

    @Test func aCheckoutThatMovesToTheReleaseDownloadSaysSo() {
        let line = InstallKind.checkout(repo: "/Users/me/src/hook").line(home: "/Users/me", movesToRelease: true)
        #expect(line.mode == "Developer checkout")
        #expect(line.detail == "Hook runs from the git checkout ~/src/hook. The next Check for Updates moves it to the release download in ~/.local/share/hook/current, with no git or compiler, and leaves the checkout as it is.")
        #expect(InstallKind.checkout(repo: "/Users/me/src/hook").line(home: "/Users/me", movesToRelease: false)
            == InstallKind.checkout(repo: "/Users/me/src/hook").line(home: "/Users/me"))
        #expect(InstallKind.release(home: "/Users/me/.local/share/hook").line(home: "/Users/me", movesToRelease: true)
            == InstallKind.release(home: "/Users/me/.local/share/hook").line(home: "/Users/me"))
    }
}

@Suite struct ReleaseAssetsTests {
    private let zipHash = String(repeating: "ab", count: 32)

    @Test func theFilesComeFromTheTagsReleaseOnGitHub() throws {
        let version = try #require(ReleaseVersion("v0.10.0"))
        #expect(ReleaseAssets.zipName(version) == "Hook-0.10.0.zip")
        #expect(ReleaseAssets.url(tag: "v0.10.0", file: "Hook-0.10.0.zip").absoluteString
            == "https://github.com/xooxoxxo/hook/releases/download/v0.10.0/Hook-0.10.0.zip")
        #expect(ReleaseAssets.url(tag: "v0.10.0", file: ReleaseAssets.sumsName).absoluteString
            == "https://github.com/xooxoxxo/hook/releases/download/v0.10.0/SHA256SUMS")
    }

    @Test func theChecksumIsTheLineThatNamesTheZip() {
        let sums = "\(String(repeating: "cd", count: 32))  Other.zip\n\(zipHash)  Hook-0.10.0.zip\n"
        #expect(ReleaseAssets.checksum(in: sums, for: "Hook-0.10.0.zip") == zipHash)
        #expect(ReleaseAssets.checksum(in: "\(zipHash.uppercased())  Hook-0.10.0.zip", for: "Hook-0.10.0.zip") == zipHash)
        #expect(ReleaseAssets.checksum(in: "\(zipHash) *Hook-0.10.0.zip", for: "Hook-0.10.0.zip") == zipHash)
        #expect(ReleaseAssets.checksum(in: sums, for: "Hook-0.10.1.zip") == nil)
        #expect(ReleaseAssets.checksum(in: "abc  Hook-0.10.0.zip", for: "Hook-0.10.0.zip") == nil)
        #expect(ReleaseAssets.checksum(in: "\(zipHash)  Hook-0.10.0.zip.sig", for: "Hook-0.10.0.zip") == nil)
        #expect(ReleaseAssets.checksum(in: "", for: "Hook-0.10.0.zip") == nil)
    }

    @Test func verifyHashesTheBytes() {
        let data = Data("hello\n".utf8)
        let hash = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        #expect(ReleaseAssets.sha256(data) == hash)
        #expect(ReleaseAssets.verify(data, sums: "\(hash)  Hook-1.0.0.zip\n", name: "Hook-1.0.0.zip") == nil)
        #expect(ReleaseAssets.verify(Data("hellO\n".utf8), sums: "\(hash)  Hook-1.0.0.zip\n", name: "Hook-1.0.0.zip")
            == UpdateCheckError("Hook-1.0.0.zip doesn't match the release's SHA256SUMS, so it wasn't installed."))
        #expect(ReleaseAssets.verify(data, sums: "", name: "Hook-1.0.0.zip")
            == UpdateCheckError("The release's SHA256SUMS doesn't list Hook-1.0.0.zip."))
    }
}

@Suite struct ReleaseUpdatePlanTests {
    private func plan(home: String = "/Users/me/.local/share/hook") -> ReleaseUpdatePlan {
        ReleaseUpdatePlan(
            hookHome: home, tag: "v0.10.1", version: ReleaseVersion("0.10.1")!, current: "0.10.0",
            appPath: "/Users/me/Applications/Hook.app", downloadDir: "/tmp/hook-update-1",
            zipPath: "/tmp/hook-update-1/Hook-0.10.1.zip", sumsPath: "/tmp/hook-update-1/SHA256SUMS",
            logPath: "/Users/me/Library/Logs/Hook/update.log", scriptPath: "/tmp/relay-update.sh",
            plistPath: "/tmp/relay-update.plist", home: "/Users/me")
    }

    @Test func theScriptInstallsTheCheckedFilesWithTheInstalledGetSh() {
        let lines = plan().script.split(separator: "\n").map(String.init)
        #expect(lines.first == "#!/bin/sh")
        let steps = lines.filter { !$0.hasPrefix(" ") && $0.contains("|| fail") }
        #expect(steps == [
            "cd '/Users/me/.local/share/hook' || fail \"couldn't open the Hook folder\"",
            "HOOK_VERSION='0.10.1' HOOK_ZIP='/tmp/hook-update-1/Hook-0.10.1.zip' HOOK_SUMS='/tmp/hook-update-1/SHA256SUMS' "
                + "/bin/bash '/Users/me/.local/share/hook/current/scripts/get.sh' || fail \"scripts/get.sh\"",
        ])
        #expect(lines.last == "finish")
        #expect(!plan().script.contains("/usr/bin/git"))
    }

    @Test func theJobRemovesItsDownloadAndItselfAndRestartsHookOnFailure() {
        let script = plan().script
        #expect(script.contains("rm -rf '/tmp/hook-update-1'"))
        #expect(script.contains("rm -f '/tmp/relay-update.plist' '/tmp/relay-update.sh'"))
        #expect(script.contains("exec /bin/launchctl remove 'io.github.xooxoxxo.relay.update'"))
        #expect(script.contains("/usr/bin/pgrep -u \"$(/usr/bin/id -u)\" -x Hook >/dev/null 2>&1 || /usr/bin/open -g -a '/Users/me/Applications/Hook.app'"))
        #expect(script.contains("export HOME='/Users/me'"))
        #expect(script.contains("\nexport HOOK_QUIT_BY=updater\n"))
    }

    @Test func pathsAreQuoted() {
        #expect(plan(home: "/Users/me/it's").script.contains("cd '/Users/me/it'\\''s' || fail"))
    }

    private func moving() -> ReleaseUpdatePlan {
        var plan = plan()
        plan.fromCheckout = "/Users/me/src/hook"
        return plan
    }

    /// A checkout has no installed get.sh: the job runs the one in the checked zip, which
    /// installs to ~/.local/share/hook and points the config's repoPath at current.
    @Test func aCheckoutMovesWithTheGetShInTheCheckedZip() {
        let script = moving().script
        let lines = script.split(separator: "\n").map(String.init)
        let steps = lines.filter { !$0.hasPrefix(" ") && $0.contains("|| fail") }
        #expect(steps == [
            "cd '/tmp/hook-update-1' || fail \"couldn't open the download\"",
            "/usr/bin/unzip -q -o '/tmp/hook-update-1/Hook-0.10.1.zip' 'support/scripts/get.sh' -d '/tmp/hook-update-1/payload' "
                + "|| fail \"couldn't unpack get.sh from Hook-0.10.1.zip\"",
            "HOOK_VERSION='0.10.1' HOOK_ZIP='/tmp/hook-update-1/Hook-0.10.1.zip' HOOK_SUMS='/tmp/hook-update-1/SHA256SUMS' "
                + "/bin/bash '/tmp/hook-update-1/payload/support/scripts/get.sh' || fail \"scripts/get.sh\"",
        ])
        #expect(lines.contains("echo \"update: moving off the checkout\" '/Users/me/src/hook' \"(left as it is)\""))
        #expect(!script.contains("/current/scripts/get.sh"))
        #expect(!script.contains("/usr/bin/git"))
        #expect(script.contains("rm -rf '/tmp/hook-update-1'"))
        // ~/.local/share/hook may not exist yet: the job starts in the download folder.
        #expect(moving().jobPlist["WorkingDirectory"] as? String == "/tmp/hook-update-1")
    }

    @Test func theJobIsTheSameOneShotLaunchdJob() {
        let job = plan().jobPlist
        #expect(job["Label"] as? String == UpdatePlan.jobLabel)
        #expect(job["ProgramArguments"] as? [String] == ["/bin/sh", "/tmp/relay-update.sh"])
        #expect(job["WorkingDirectory"] as? String == "/Users/me/.local/share/hook")
        #expect(job["AbandonProcessGroup"] as? Bool == true)
        #expect(job["StandardOutPath"] as? String == "/Users/me/Library/Logs/Hook/update.log")
        #expect(plan().launchCommands(uid: 501).last == ["/bin/launchctl", "bootstrap", "gui/501", "/tmp/relay-update.plist"])
    }
}
