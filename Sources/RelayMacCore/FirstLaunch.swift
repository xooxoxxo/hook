import Foundation
import RelayCore

/// Where a running Hook.app is, as its first launch sees it.
public enum AppLocation: Equatable, Sendable {
    /// In `/Applications` or `~/Applications` (or a folder inside them).
    case applications
    /// On a mounted volume: the disk image it came in, or another disk.
    case volume
    /// App Translocation: macOS runs a quarantined download from a random read-only path
    /// until the owner moves it, so its real place is unknown.
    case translocated
    /// Anywhere else: Downloads, the Desktop, a build folder.
    case elsewhere

    public static func of(bundlePath: String, home: String) -> AppLocation {
        var path = (bundlePath as NSString).standardizingPath
        // The firmlinked data volume names the same folders.
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        if path.contains("/AppTranslocation/") { return .translocated }
        let home = (home as NSString).standardizingPath
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.hasPrefix("/Volumes/") { return .volume }
        return .elsewhere
    }
}

/// Hook's first launch from a download (the DMG): with no config yet, a Hook in Applications
/// installs the release it carries in `Contents/Resources/support`, with the copy of get.sh
/// in it (HOOK_BUNDLE): the `relay` command, MCP server, skill and agent setup, and a config
/// with setup pending, the same as the one-line installer. Elsewhere it first asks the owner
/// to move it to Applications.
public enum FirstLaunch {
    /// The support payload inside Hook.app, sealed and notarized with it.
    public static let supportFolder = "Contents/Resources/support"
    public static let applicationsFolder = "/Applications"

    public enum Decision: Equatable, Sendable {
        /// A config exists, the app carries no payload (a developer's build), or a test run.
        case nothing
        case moveToApplications(MoveOffer)
        case install(InstallJob)
    }

    /// - environment: `RELAY_CONFIG` or `RELAY_DATA_DIR` (tests and the smoke run) never install.
    /// - isWritable: whether a folder can take a new app (`applicationsFolder`).
    public static func decide(bundlePath: String, home: String, environment: [String: String],
                              fileExists: (String) -> Bool, isWritable: (String) -> Bool,
                              applications: String = applicationsFolder) -> Decision {
        for key in ["RELAY_CONFIG", "RELAY_DATA_DIR"] where !(environment[key] ?? "").isEmpty { return .nothing }
        let bundle = (bundlePath as NSString).standardizingPath
        let getSh = bundle + "/" + supportFolder + "/scripts/get.sh"
        guard fileExists(getSh) else { return .nothing }
        guard !fileExists(home + "/.config/relay/config.json") else { return .nothing }
        let location = AppLocation.of(bundlePath: bundle, home: home)
        if location == .applications {
            return .install(InstallJob(bundlePath: bundle, home: home))
        }
        let destination = applications + "/Hook.app"
        let action: MoveOffer.Action?
        if location == .translocated {
            action = nil
        } else if fileExists(destination) {
            action = .openExisting
        } else if !isWritable(applications) {
            action = nil
        } else {
            action = location == .volume ? .copy : .move
        }
        return .moveToApplications(MoveOffer(location: location, source: bundle, destination: destination, action: action))
    }
}

/// The alert that asks for a move to Applications, and what its first button does.
public struct MoveOffer: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// From a disk image (read-only): copy the app to Applications, open the copy.
        case copy
        /// From another folder: move the app to Applications, open it there.
        case move
        /// Applications already holds a Hook.app: open that one.
        case openExisting
    }

    public var location: AppLocation
    public var source: String
    public var destination: String
    /// nil: Hook can't do it (a translocated copy, or Applications isn't writable), so the
    /// alert only says how, and quits.
    public var action: Action?

    public init(location: AppLocation, source: String, destination: String, action: Action?) {
        self.location = location
        self.source = source
        self.destination = destination
        self.action = action
    }

    public var title: String { "Move Hook to Applications" }

    public var detail: String {
        let why = "Hook runs from the Applications folder, where it can set up the relay command and your agents and update itself."
        switch action {
        case .copy?: return why + " It is running from the disk image now. Hook can copy itself there and open the copy."
        case .move?: return why + " Hook can move itself there and open from there."
        case .openExisting?: return why + " There is already a Hook.app in Applications. Open that one, and eject the disk image or delete this copy."
        case nil:
            switch location {
            case .translocated:
                return why + " macOS is running a temporary copy of the download. Quit Hook, drag Hook to the Applications folder in Finder, then open it from there."
            case .volume:
                return why + " Quit Hook, drag Hook onto the Applications folder in the disk image's window, then open it from Applications."
            case .applications, .elsewhere:
                return why + " Quit Hook, drag it to the Applications folder in Finder, then open it from there."
            }
        }
    }

    /// The buttons, first one the default. Quit is always last.
    public var buttons: [String] {
        switch action {
        case .copy?: ["Copy to Applications", "Quit"]
        case .move?: ["Move to Applications", "Quit"]
        case .openExisting?: ["Open Hook in Applications", "Quit"]
        case nil: ["Quit"]
        }
    }

    /// Copies or moves the app to `destination`, never over anything there. Returns the app to
    /// open next.
    public func relocate(fileManager: FileManager = .default) throws -> String {
        switch action {
        case .copy?: try fileManager.copyItem(atPath: source, toPath: destination)
        case .move?: try fileManager.moveItem(atPath: source, toPath: destination)
        case .openExisting?, nil: break
        }
        return destination
    }
}

/// The bundled get.sh run, and the log it writes.
public struct InstallJob: Equatable, Sendable {
    public var bundlePath: String
    public var home: String

    public init(bundlePath: String, home: String) {
        self.bundlePath = bundlePath
        self.home = home
    }

    public var executable: String { "/bin/bash" }
    public var script: String { bundlePath + "/" + FirstLaunch.supportFolder + "/scripts/get.sh" }
    public var arguments: [String] { [script] }
    public var logPath: String { HookLog.directory(home: home).appending(path: "first-launch.log").path }

    /// HOME, a PATH that finds the harness CLIs (as the updater's job has), and HOOK_BUNDLE. Only
    /// these: the app's own environment can hold test switches that would change the install.
    public var environment: [String: String] {
        [
            "HOME": home,
            "PATH": home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOOK_BUNDLE": bundlePath,
            "LANG": "en_US.UTF-8",
        ]
    }

    /// Runs get.sh off the main thread, its output appended to `logPath`; returns its status
    /// (3: nothing was changed), or -1 when it couldn't start.
    public func run() async -> Int32 {
        let log = URL(fileURLWithPath: logPath)
        try? PrivateFile.createDirectoryIfMissing(log.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
        _ = try? handle.seekToEnd()
        handle.write(Data("first launch: \(Date()) installing from \(bundlePath)\n".utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { @Sendable finished in
                try? handle.close()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? handle.close()
                continuation.resume(returning: -1)
            }
        }
    }

    /// The alert after a failed install. Setup still works for the queue without it.
    public func failure(status: Int32) -> (title: String, detail: String) {
        let log = TildePath.abbreviate(logPath, home: home)
        return ("Hook couldn't finish installing",
                "The relay command, the MCP server and the agent setup aren't installed yet (status \(status)). "
                + "If macOS offered to install the command line developer tools, install them, then try again. "
                + "The log is in \(log).")
    }
}
