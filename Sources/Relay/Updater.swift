import AppKit
import RelayCore

/// Asks GitHub for the latest release about a minute after launch, then once a day.
/// A failed automatic check changes nothing and posts nothing; the next one tries again.
@MainActor final class UpdateChecker {
    static let releaseURL = URL(string: UpdateGate.latestReleaseAPI)!
    private static let lastCheckKey = "updateLastCheck"
    private static let latestTagKey = "updateLatestTag"
    private static let latestURLKey = "updateLatestURL"
    private static let latestMailboxLevelKey = "updateLatestMailboxLevel"

    private(set) var state: UpdateState = .none
    /// The mailbox level the available release needs (its notes' marker); nil when it has none.
    private(set) var requiredMailboxLevel: Int?
    var onChange: (@MainActor () -> Void)?
    private let defaults: UserDefaults
    private let current: String
    private var timer: Task<Void, Never>?
    private var inFlight: Task<UpdateState, Never>?

    init(defaults: UserDefaults = .standard, current: String = UpdateChecker.runningVersion) {
        self.defaults = defaults
        self.current = current
        let stored = Self.storedRelease(defaults)
        state = UpdateState.resolve(current: current, latest: stored)
        requiredMailboxLevel = stored?.mailboxLevel
    }

    nonisolated static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    func start() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(UpdateSchedule.firstDelay))
            while !Task.isCancelled {
                _ = await self?.check()
                try? await Task.sleep(for: .seconds(UpdateSchedule.interval))
            }
        }
    }

    /// One check now; a check already running is joined. Returns its result, while
    /// `state` keeps what it knew when the check fails.
    func check() async -> UpdateState {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in await self.perform() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func perform() async -> UpdateState {
        let previous = state
        let reply = await Self.fetch()
        let result = UpdateState.resolve(current: current, reply: reply)
        defaults.set(Date(), forKey: Self.lastCheckKey)
        switch result {
        case .failed:
            state = previous
        case .available(_, let tag, let url):
            defaults.set(tag, forKey: Self.latestTagKey)
            defaults.set(url.absoluteString, forKey: Self.latestURLKey)
            let level = (try? reply.get()).flatMap(LatestRelease.parse)?.mailboxLevel
            if let level { defaults.set(level, forKey: Self.latestMailboxLevelKey) } else {
                defaults.removeObject(forKey: Self.latestMailboxLevelKey)
            }
            requiredMailboxLevel = level
            state = result
        case .none, .checking:
            state = .none
        }
        onChange?()
        return result
    }

    private static func storedRelease(_ defaults: UserDefaults) -> LatestRelease? {
        guard let tag = defaults.string(forKey: latestTagKey), let version = ReleaseVersion(tag),
              let page = defaults.string(forKey: latestURLKey), let url = URL(string: page) else { return nil }
        let level = defaults.object(forKey: latestMailboxLevelKey) as? Int
        return LatestRelease(tag: tag, version: version, url: url, mailboxLevel: level)
    }

    private static func fetch() async -> Result<Data, UpdateCheckError> {
        var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hook/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(UpdateCheckError("GitHub answered \(status).")) }
            return .success(data)
        } catch {
            return .failure(UpdateCheckError(UserFacingError.text(error)))
        }
    }
}

/// Updates Hook in a one-shot launchd job, so the job outlives install.sh quitting this app.
/// A release download gets the release's zip, checked against its SHA256SUMS here and again
/// by get.sh; a checkout (developer mode) moves to the release tag and rebuilds.
enum UpdateRunner {
    static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    static var logPath: String { home + "/Library/Logs/Relay/update.log" }
    static var appPath: String { home + "/Applications/Hook.app" }

    /// The gate: the folder is the Hook repo, its origin is xooxoxxo/hook or xooxoxxo/relay, the tree is
    /// clean, and HEAD is main or a release tag. Runs git off the main thread.
    static func gate(repoPath: String?) async -> Result<(repo: String, mode: UpdateGate.Mode), UpdateCheckError> {
        guard let raw = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(UpdateCheckError("Hook doesn't know where your checkout is. Set it in Settings › Connect, or run scripts/install.sh once."))
        }
        let repo = ConnectInfo.normalized(raw)
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        guard ConnectInfo.isRepo(repo, fileExists: exists), exists(repo + "/scripts/install.sh") else {
            return .failure(UpdateCheckError("\(TildePath.abbreviate(repo, home: home)) isn't the Hook repo."))
        }
        return await Task.detached {
            guard let origin = git(repo, ["remote", "get-url", "origin"]), UpdateGate.isRepoOrigin(origin) else {
                return .failure(UpdateCheckError("The checkout's origin isn't github.com/xooxoxxo/hook (or xooxoxxo/relay)."))
            }
            guard let porcelain = git(repo, ["status", "--porcelain"]),
                  let branch = git(repo, ["branch", "--show-current"]) else {
                return .failure(UpdateCheckError("git couldn't read the checkout."))
            }
            let tag = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? git(repo, ["describe", "--tags", "--exact-match", "HEAD"]) : nil
            switch UpdateGate.check(porcelain: porcelain, branch: branch, headTag: tag) {
            case .ok(let mode): return .success((repo, mode))
            case .refused(let reason): return .failure(UpdateCheckError(reason))
            }
        }.value
    }

    /// The files of one release download, checked against its SHA256SUMS.
    struct Download {
        let dir: URL
        let zip: URL
        let sums: URL
    }

    /// Downloads the release's zip and SHA256SUMS into a private temp folder and checks the
    /// zip's hash. Off the main thread; the folder is removed again on any failure.
    static func downloadRelease(tag: String, version: ReleaseVersion) async -> Result<Download, UpdateCheckError> {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "hook-update-\(UUID().uuidString.prefix(8))")
        let name = ReleaseAssets.zipName(version)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let sumsData = try await fetch(session, ReleaseAssets.url(tag: tag, file: ReleaseAssets.sumsName))
            let zipData = try await fetch(session, ReleaseAssets.url(tag: tag, file: name))
            let sums = String(decoding: sumsData, as: UTF8.self)
            if let problem = ReleaseAssets.verify(zipData, sums: sums, name: name) { throw problem }
            let download = Download(dir: dir, zip: dir.appending(path: name), sums: dir.appending(path: ReleaseAssets.sumsName))
            try zipData.write(to: download.zip, options: .atomic)
            try sumsData.write(to: download.sums, options: .atomic)
            return .success(download)
        } catch {
            try? fm.removeItem(at: dir)
            if let error = error as? UpdateCheckError { return .failure(error) }
            return .failure(UpdateCheckError("Couldn't download the release. " + UserFacingError.text(error)))
        }
    }

    private static func fetch(_ session: URLSession, _ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Hook/\(UpdateChecker.runningVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, response.url?.scheme == "https" else {
            throw UpdateCheckError("GitHub answered \(status) for \(url.lastPathComponent).")
        }
        return data
    }

    /// Starts the job that installs a checked download with the installed get.sh.
    static func launchRelease(hookHome: String, tag: String, version: ReleaseVersion, download: Download) throws {
        let id = UUID().uuidString.prefix(8)
        let temp = FileManager.default.temporaryDirectory
        let plan = ReleaseUpdatePlan(
            hookHome: hookHome, tag: tag, version: version, current: UpdateChecker.runningVersion, appPath: appPath,
            downloadDir: download.dir.path, zipPath: download.zip.path, sumsPath: download.sums.path, logPath: logPath,
            scriptPath: temp.appending(path: "relay-update-\(id).sh").path,
            plistPath: temp.appending(path: "relay-update-\(id).plist").path, home: home)
        do {
            try load(plan)
        } catch {
            try? FileManager.default.removeItem(at: download.dir)
            throw error
        }
    }

    /// Writes the script and the job's plist to the temp folder and loads the job.
    static func launch(repo: String, tag: String, mode: UpdateGate.Mode) throws {
        let id = UUID().uuidString.prefix(8)
        let temp = FileManager.default.temporaryDirectory
        let plan = UpdatePlan(
            repoPath: repo, tag: tag, mode: mode, current: UpdateChecker.runningVersion, appPath: appPath,
            logPath: logPath, scriptPath: temp.appending(path: "relay-update-\(id).sh").path,
            plistPath: temp.appending(path: "relay-update-\(id).plist").path, home: home)
        try load(plan)
    }

    private static func load(_ plan: some UpdateJob) throws {
        try FileManager.default.createDirectory(
            atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(plan.script.utf8).write(to: URL(fileURLWithPath: plan.scriptPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: plan.scriptPath)
        let plist = try PropertyListSerialization.data(fromPropertyList: plan.jobPlist, format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: plan.plistPath), options: .atomic)
        let commands = plan.launchCommands(uid: getuid())
        _ = run(commands[0])   // a stale job of the same label; usually not there
        guard run(commands[1]) == 0 else {
            try? FileManager.default.removeItem(atPath: plan.plistPath)
            try? FileManager.default.removeItem(atPath: plan.scriptPath)
            throw UpdateCheckError("launchctl couldn't start the update.")
        }
    }

    /// `/usr/bin/git -C <repo> …`'s output, or nil when it fails.
    private nonisolated static func git(_ repo: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func run(_ command: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
