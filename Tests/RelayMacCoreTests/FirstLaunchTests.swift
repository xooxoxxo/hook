import Foundation
import Testing
@testable import RelayCore
@testable import RelayMacCore

@Suite struct AppLocationTests {
    private let home = "/Users/me"

    @Test func applicationsFoldersCountWherever() {
        #expect(AppLocation.of(bundlePath: "/Applications/Hook.app", home: home) == .applications)
        #expect(AppLocation.of(bundlePath: "/Applications/Utilities/Hook.app/", home: home) == .applications)
        #expect(AppLocation.of(bundlePath: "/Users/me/Applications/Hook.app", home: home) == .applications)
        #expect(AppLocation.of(bundlePath: "/System/Volumes/Data/Applications/Hook.app", home: home) == .applications)
    }

    @Test func theDiskImageTranslocationAndOtherFoldersAreNot() {
        #expect(AppLocation.of(bundlePath: "/Volumes/Hook 0.16.0/Hook.app", home: home) == .volume)
        #expect(AppLocation.of(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/1A2B-3C4D/d/Hook.app", home: home) == .translocated)
        #expect(AppLocation.of(bundlePath: "/Users/me/Downloads/Hook.app", home: home) == .elsewhere)
        #expect(AppLocation.of(bundlePath: "/Users/other/Applications/Hook.app", home: home) == .elsewhere)
        #expect(AppLocation.of(bundlePath: "/ApplicationsOld/Hook.app", home: home) == .elsewhere)
    }
}

@Suite struct FirstLaunchDecisionTests {
    private let home = "/Users/me"
    private let config = "/Users/me/.config/relay/config.json"

    private func payload(_ bundle: String) -> String { bundle + "/Contents/Resources/support/scripts/get.sh" }

    private func decide(_ bundle: String, files: Set<String> = [], writable: Bool = true,
                        environment: [String: String] = [:]) -> FirstLaunch.Decision {
        FirstLaunch.decide(bundlePath: bundle, home: home, environment: environment,
                           fileExists: { files.contains($0) }, isWritable: { _ in writable })
    }

    @Test func noConfigInApplicationsInstallsFromTheBundle() {
        let app = "/Applications/Hook.app"
        #expect(decide(app, files: [payload(app)]) == .install(InstallJob(bundlePath: app, home: home)))
        let mine = "/Users/me/Applications/Hook.app"
        #expect(decide(mine, files: [payload(mine)]) == .install(InstallJob(bundlePath: mine, home: home)))
    }

    @Test func aConfigABuildWithoutPayloadOrATestRunDoNothing() {
        let app = "/Applications/Hook.app"
        #expect(decide(app, files: [payload(app), config]) == .nothing)
        #expect(decide(app, files: []) == .nothing)
        #expect(decide(app, files: [payload(app)], environment: ["RELAY_CONFIG": "/tmp/c.json"]) == .nothing)
        #expect(decide(app, files: [payload(app)], environment: ["RELAY_DATA_DIR": "/tmp/d"]) == .nothing)
        #expect(decide(app, files: [payload(app)], environment: ["RELAY_CONFIG": ""])
            == .install(InstallJob(bundlePath: app, home: home)))
        // A config, wherever the app is, is an existing install: no move alert either.
        let dmg = "/Volumes/Hook/Hook.app"
        #expect(decide(dmg, files: [payload(dmg), config]) == .nothing)
    }

    @Test func theDiskImageOffersACopyAndAFolderAMove() {
        let dmg = "/Volumes/Hook/Hook.app"
        #expect(decide(dmg, files: [payload(dmg)]) == .moveToApplications(MoveOffer(
            location: .volume, source: dmg, destination: "/Applications/Hook.app", action: .copy)))
        let downloads = "/Users/me/Downloads/Hook.app"
        #expect(decide(downloads, files: [payload(downloads)]) == .moveToApplications(MoveOffer(
            location: .elsewhere, source: downloads, destination: "/Applications/Hook.app", action: .move)))
    }

    @Test func translocationATakenPlaceOrAReadOnlyFolderOnlyInstruct() {
        let moved = "/private/var/folders/xy/T/AppTranslocation/1A2B/d/Hook.app"
        guard case .moveToApplications(let translocated) = decide(moved, files: [payload(moved)]) else {
            Issue.record("no move offer"); return
        }
        #expect(translocated.action == nil)
        #expect(translocated.buttons == ["Quit"])
        #expect(translocated.detail.contains("temporary copy"))
        let dmg = "/Volumes/Hook/Hook.app"
        guard case .moveToApplications(let taken) = decide(dmg, files: [payload(dmg), "/Applications/Hook.app"]) else {
            Issue.record("no move offer"); return
        }
        #expect(taken.action == .openExisting)
        #expect(taken.buttons.first == "Open Hook in Applications")
        guard case .moveToApplications(let locked) = decide(dmg, files: [payload(dmg)], writable: false) else {
            Issue.record("no move offer"); return
        }
        #expect(locked.action == nil)
        #expect(locked.detail.contains("disk image's window"))
    }

    @Test func everyOfferEndsWithQuit() {
        for action in [MoveOffer.Action.copy, .move, .openExisting, nil] {
            let offer = MoveOffer(location: .volume, source: "/Volumes/Hook/Hook.app", destination: "/Applications/Hook.app", action: action)
            #expect(offer.buttons.last == "Quit")
            #expect(offer.title == "Move Hook to Applications")
            #expect(offer.detail.contains("Applications folder"))
        }
    }
}

@Suite struct MoveOfferRelocateTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hook-move-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func app(in folder: URL) throws -> String {
        let app = folder.appending(path: "Hook.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: app.appending(path: "Info.plist"))
        return folder.appending(path: "Hook.app").path
    }

    @Test func aCopyLeavesTheSourceAndAMoveTakesIt() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try app(in: root.appending(path: "Volume"))
        try FileManager.default.createDirectory(at: root.appending(path: "Applications"), withIntermediateDirectories: true)
        let destination = root.appending(path: "Applications/Hook.app").path
        let copy = MoveOffer(location: .volume, source: source, destination: destination, action: .copy)
        #expect(try copy.relocate() == destination)
        #expect(FileManager.default.fileExists(atPath: source + "/Contents/Info.plist"))
        #expect(FileManager.default.fileExists(atPath: destination + "/Contents/Info.plist"))
        // Never over an app that is there.
        #expect(throws: (any Error).self) { try copy.relocate() }
        try FileManager.default.removeItem(atPath: destination)
        let move = MoveOffer(location: .elsewhere, source: source, destination: destination, action: .move)
        #expect(try move.relocate() == destination)
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(FileManager.default.fileExists(atPath: destination + "/Contents/Info.plist"))
        let open = MoveOffer(location: .volume, source: source, destination: destination, action: .openExisting)
        #expect(try open.relocate() == destination)
    }
}

@Suite struct FirstLaunchInstallTests {
    @Test func theJobRunsTheBundledGetShWithHookBundleAndAPlainEnvironment() {
        let job = InstallJob(bundlePath: "/Applications/Hook.app", home: "/Users/me")
        #expect(job.executable == "/bin/bash")
        #expect(job.arguments == ["/Applications/Hook.app/Contents/Resources/support/scripts/get.sh"])
        #expect(job.environment["HOOK_BUNDLE"] == "/Applications/Hook.app")
        #expect(job.environment["HOME"] == "/Users/me")
        #expect(job.environment["PATH"]?.hasPrefix("/Users/me/.local/bin:") == true)
        #expect(job.environment["PATH"]?.contains("/usr/bin:/bin") == true)
        // No test switch of the app's own environment reaches the installer.
        #expect(Set(job.environment.keys) == ["HOME", "PATH", "HOOK_BUNDLE", "LANG"])
        #expect(job.logPath == "/Users/me/Library/Logs/Hook/first-launch.log")
        let failure = job.failure(status: 1)
        #expect(failure.detail.contains("~/Library/Logs/Hook/first-launch.log"))
        #expect(failure.detail.contains("command line developer tools"))
    }

    /// The real run: a stand-in get.sh in a stand-in app prints what it got, into the log.
    @Test func runPassesTheEnvironmentAndReturnsTheStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hook-first-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Applications/Hook.app")
        let scripts = app.appending(path: "Contents/Resources/support/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let script = "echo \"bundle=$HOOK_BUNDLE home=$HOME pwd=$(pwd -P) args=$#\"\nexit ${STUB_STATUS:-7}\n"
        try Data(script.utf8).write(to: scripts.appending(path: "get.sh"))
        let job = InstallJob(bundlePath: app.path, home: home.path)
        #expect(await job.run() == 7)
        let log = try String(contentsOfFile: job.logPath, encoding: .utf8)
        #expect(log.contains("first launch: "))
        #expect(log.contains("bundle=\(app.path) home=\(home.path)"))
        // It runs in the home folder (pwd -P resolves /var to /private/var), with no arguments.
        #expect(log.contains("/" + root.lastPathComponent + "/home args=0"))
        // A second run appends.
        #expect(await job.run() == 7)
        let again = try String(contentsOfFile: job.logPath, encoding: .utf8)
        #expect(again.components(separatedBy: "first launch: ").count == 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: job.logPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aMissingScriptFailsWithoutHanging() async {
        let job = InstallJob(bundlePath: "/nonexistent-\(UUID().uuidString)/Hook.app",
                             home: FileManager.default.temporaryDirectory.appending(path: "hook-none-\(UUID().uuidString.prefix(8))").path)
        defer { try? FileManager.default.removeItem(atPath: job.home) }
        #expect(await job.run() != 0)
    }
}

@Suite struct UpdaterAppPathTests {
    @Test func anUpdateReplacesTheAppInApplicationsElseTheDefault() {
        #expect(UpdateRunner.appPath(bundlePath: "/Applications/Hook.app", home: "/Users/me") == "/Applications/Hook.app")
        #expect(UpdateRunner.appPath(bundlePath: "/Users/me/Applications/Hook.app", home: "/Users/me") == "/Users/me/Applications/Hook.app")
        #expect(UpdateRunner.appPath(bundlePath: "/Users/me/src/hook/build/Hook.app", home: "/Users/me")
            == "/Users/me/Applications/Hook.app")
        #expect(UpdateRunner.appPath(bundlePath: "/Volumes/Hook/Hook.app", home: "/Users/me") == "/Users/me/Applications/Hook.app")
        #expect(UpdateRunner.appPath(bundlePath: "/Applications/Other.app", home: "/Users/me") == "/Users/me/Applications/Hook.app")
    }
}
