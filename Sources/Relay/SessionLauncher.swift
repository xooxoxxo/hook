import AppKit
import RelayCore

/// Runs Resume Session: finds the chosen terminal, runs its `LaunchPlan` step by step
/// (the next step only after a failure) and says why when every step failed.
/// Blocking work (osascript, `alacritty msg`) runs off the main actor.
@MainActor final class SessionLauncher {
    struct Failure: Error {
        let reason: String
    }

    /// Private (0700) folder for the `.command` files; emptied at launch.
    let launchDirectory: URL
    let home: URL

    init(dataDirectory: URL, home: URL) {
        launchDirectory = dataDirectory.appending(path: "launch", directoryHint: .isDirectory)
        self.home = home
    }

    /// The known terminals that are installed, by bundle id.
    static func installed() -> Set<TerminalKind> {
        Set(TerminalKind.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil })
    }

    /// Removes `.command` files a terminal never ran (each one removes itself when it runs).
    func sweep() {
        let files = (try? FileManager.default.contentsOfDirectory(at: launchDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "command" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Nil when a terminal opened; else the reason, display-ready.
    func resume(_ origin: AskOrigin, setting: String) async -> String? {
        guard let target = ResumeTarget(origin) else { return "This ask has no session to resume." }
        if case .unavailable(let reason) = ResumeAvailability.of(origin, localHost: HostName.current) { return reason + "." }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "The session's folder no longer exists."
        }
        var kind = TerminalKind.resolve(setting, installed: Self.installed())
        var appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID)
        if appURL == nil, kind != .terminal {
            kind = .terminal
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID)
        }
        guard let appURL else { return "\(kind.name) isn't installed." }
        let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let plan = TerminalLauncher.plan(kind, target: target, shell: Self.loginShell(), ghosttyVersion: version)
        var last = "\(kind.name) didn't open."
        for step in plan.steps {
            do {
                try await run(step, appURL: appURL)
                return nil
            } catch let failure as Failure {
                last = failure.reason
            } catch {
                last = "\(kind.name) didn't open: \(error.localizedDescription)"
            }
        }
        return last
    }

    /// The user's login shell from the password database; `$SHELL` can be stale or unset for a GUI app.
    static func loginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    private func run(_ step: LaunchStep, appURL: URL) async throws {
        switch step {
        case let .commandFile(body, _):
            try PrivateFile.ensureDirectory(launchDirectory)
            let file = launchDirectory.appending(path: "resume-\(UUID().uuidString).command")
            try PrivateFile.write(Data(body.utf8), to: file)
            guard chmod(file.path, 0o700) == 0 else {
                try? FileManager.default.removeItem(at: file)
                throw Failure(reason: "Couldn't prepare the launch file.")
            }
            do {
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: appURL,
                                                      configuration: NSWorkspace.OpenConfiguration())
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        case let .openNew(_, arguments):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        case let .process(bundleID, executable, arguments, waits):
            let path = appURL.appending(path: executable).path
            let result = try await Self.spawn(path, arguments, waits: waits)
            if waits, result.status != 0 { throw Failure(reason: "The terminal refused the new window.") }
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        case let .appleScript(source, arguments):
            let result = try await Self.spawn("/usr/bin/osascript", ["-e", source] + arguments, waits: true)
            guard result.status == 0 else {
                if result.stderr.contains("-1743") {
                    throw Failure(reason: "Hook isn't allowed to control the terminal (System Settings › Privacy & Security › Automation).")
                }
                throw Failure(reason: "The terminal's AppleScript failed.")
            }
        case let .fileThenURL(file, contents, url):
            try PrivateFile.write(Data(contents.utf8), to: home.appending(path: file))
            guard NSWorkspace.shared.open(url) else { throw Failure(reason: "The terminal didn't take the link.") }
        }
    }

    /// Runs a process off the main actor. With `waits`, returns its exit status and
    /// stderr; otherwise returns once it started, leaving it running.
    private nonisolated static func spawn(_ path: String, _ arguments: [String],
                                          waits: Bool) async throws -> (status: Int32, stderr: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = waits ? errors : FileHandle.nullDevice
            try process.run()
            guard waits else { return (0, "") }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
