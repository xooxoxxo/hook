import Foundation
import os

/// Hook's activity log, `~/Library/Logs/Hook/hook.log`: one line per typed event, so ask
/// contents (ids, titles, steps, replies, notes), tokens, the owner key and Pond addresses
/// can't reach it. Each line is written at once, so the last ones survive a crash; it rolls
/// to `hook.1.log` at 512 KB, 1 MB in all. Every line is mirrored to the system log.
///
/// Nothing is written to disk until the app calls `start()`, so tests and tools that run
/// Hook's code never touch the real log.
public enum HookLog {
    public enum Event: Sendable, Equatable {
        case launch(hook: String, macOS: String, cpu: String)
        case quit(clean: Bool)
        case screen(Screen)
        case action(Action)
        /// The queue source and, for a Pond, its version only, never its address.
        case source(SourceKind, pond: String?)
        /// `route` is cut to its template and `message` is redacted.
        case error(type: String, status: Int?, route: String?, message: String)
        case crashFound(signature: String, report: Bool)
        /// Away mode changed; the reason is one of `PresenceLogic`'s phrases.
        case presence(PresenceState, reason: String)
    }

    public enum Screen: String, Sendable, CaseIterable {
        case queue, detail, settingsGeneral, settingsPanel, settingsQueue, settingsNotifications, settingsConnect
        case welcome, about, crashReport
    }

    public enum Action: String, Sendable, CaseIterable {
        case done, skip, reply, answer, report, message, copy, open, tick, accept, undo, update, sendCrashReport
    }

    /// The launch line for this Mac: the macOS version and the CPU type.
    public static func launch(hook: String) -> Event {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let cpu = "arm64"
        #else
        let cpu = "x86_64"
        #endif
        return .launch(hook: hook, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", cpu: cpu)
    }

    /// The longest message an error line keeps.
    static let messageLimit = 200

    private static let logger = Logger(subsystem: "Hook", category: "log")
    private static let active = OSAllocatedUnfairLock<RollingLog?>(initialState: nil)

    /// `~/Library/Logs/Hook`.
    public static var directory: URL { directory(home: home) }

    public static func directory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appending(path: "Library/Logs/Hook", directoryHint: .isDirectory)
    }

    /// The updater's log, next to `hook.log`.
    public static func updateLogPath(home: String) -> String {
        directory(home: home).appending(path: "update.log", directoryHint: .notDirectory).path
    }

    /// Moves `~/Library/Logs/Relay/update.log` (before 0.12) next to `hook.log`, once: a log
    /// already there is never overwritten. The emptied `Logs/Relay` folder goes too.
    public static func moveOldUpdateLog(home: String) {
        let fm = FileManager.default
        let oldDir = URL(fileURLWithPath: home, isDirectory: true).appending(path: "Library/Logs/Relay", directoryHint: .isDirectory)
        let old = oldDir.appending(path: "update.log", directoryHint: .notDirectory)
        let new = URL(fileURLWithPath: updateLogPath(home: home))
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try PrivateFile.createDirectoryIfMissing(new.deletingLastPathComponent())
            try fm.moveItem(at: old, to: new)
            if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true { try? fm.removeItem(at: oldDir) }
        } catch {
            HookLog.error("UpdateLog", "couldn't move the old update log: " + error.localizedDescription)
        }
    }

    /// Starts writing to `~/Library/Logs/Hook/hook.log`. The app calls it first thing at launch.
    public static func start() {
        active.withLock { $0 = RollingLog(directory: directory, now: { Date() }) }
    }

    /// Writes one line and mirrors it to the system log. A failed write is dropped:
    /// logging never stops Hook.
    public static func record(_ event: Event) {
        let line = event.line(home: home, user: NSUserName())
        logger.log("\(line, privacy: .public)")
        active.withLock { log in try? log?.append(line) }
    }

    /// An error line: `type` names where it happened, `message` is redacted.
    public static func error(_ type: String, _ message: String, status: Int? = nil, route: String? = nil) {
        record(.error(type: type, status: status, route: route, message: message))
    }

    /// The last `n` lines, oldest first, across both files.
    public static func tail(_ n: Int) -> [String] { current.tail(n) }

    /// Both files' size in bytes.
    public static var size: Int { current.size }

    /// Runs `body` with `log` as the active log, then puts the old one back. For tests.
    static func withLog(_ log: RollingLog, _ body: () throws -> Void) rethrows {
        let previous = active.withLock { state -> RollingLog? in
            let old = state
            state = log
            return old
        }
        defer { active.withLock { $0 = previous } }
        try body()
    }

    private static var current: RollingLog {
        active.withLock { $0 } ?? RollingLog(directory: directory, now: { Date() })
    }

    private static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
}

extension HookLog.Event {
    /// The line as written, without its timestamp. `home` and `user` feed the redactor.
    public func line(home: String, user: String) -> String {
        switch self {
        case .launch(let hook, let macOS, let cpu):
            return "launch hook=\(Self.safe(hook)) macos=\(Self.safe(macOS)) cpu=\(Self.safe(cpu))"
        case .quit(let clean):
            return "quit clean=\(clean)"
        case .screen(let screen):
            return "screen \(screen.rawValue)"
        case .action(let action):
            return "action \(action.rawValue)"
        case .source(let kind, let pond):
            guard let pond else { return "source \(kind.rawValue)" }
            return "source \(kind.rawValue) pond=\(Self.version(pond))"
        case .error(let type, let status, let route, let message):
            var parts = ["error", "type=\(Self.safe(type))"]
            if let status { parts.append("status=\(status)") }
            if let route { parts.append("route=\(Self.safe(RouteTemplate.template(route), extra: "{}/"))") }
            parts.append("message=\(Self.quoted(message, home: home, user: user))")
            return parts.joined(separator: " ")
        case .crashFound(let signature, let report):
            return "crash signature=\(Self.signature(signature)) report=\(report)"
        case .presence(let state, let reason):
            return "presence \(state.rawValue) reason=\(Self.quoted(reason, home: home, user: user))"
        }
    }

    /// A value cut back to the characters a version, a type or a CPU name uses.
    static func safe(_ s: String, extra: String = "") -> String {
        let kept = s.unicodeScalars.filter {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0)))
                || extra.unicodeScalars.contains($0)
        }
        let text = String(String.UnicodeScalarView(kept.prefix(64)))
        return text.isEmpty ? "?" : text
    }

    /// A Pond version, or `?` for anything that isn't one (an address never gets in).
    static func version(_ s: String) -> String {
        s.range(of: #"^\d+(\.\d+){0,2}([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) == nil ? "?" : s
    }

    static func signature(_ s: String) -> String {
        s.range(of: "^[0-9a-f]{12}$", options: .regularExpression) == nil ? "?" : s
    }

    /// Redacted, on one line, with double quotes turned single so the field can't end early.
    static func quoted(_ s: String, home: String, user: String) -> String {
        let flat = RollingLog.oneLine(s).replacingOccurrences(of: "\"", with: "'")
        var text = Redactor.redact(flat, home: home, user: user)
        if text.count > HookLog.messageLimit { text = String(text.prefix(HookLog.messageLimit)) + "…" }
        return "\"\(text)\""
    }
}

/// The file side of `HookLog`: appends with one `write(2)` on an `O_APPEND` descriptor, so a
/// line is on disk when `append` returns; at `limit` bytes `hook.log` becomes `hook.1.log`.
public struct RollingLog: Sendable {
    public let directory: URL
    public let name: String
    public let limit: Int
    private let now: @Sendable () -> Date

    public init(directory: URL, name: String = "hook.log", limit: Int = 512 * 1024,
                now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.name = name
        self.limit = limit
        self.now = now
    }

    var file: URL { directory.appending(path: name, directoryHint: .notDirectory) }

    /// `hook.log` → `hook.1.log`.
    var rotated: URL {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return directory.appending(path: ext.isEmpty ? "\(stem).1" : "\(stem).1.\(ext)", directoryHint: .notDirectory)
    }

    public func append(_ line: String) throws {
        let text = "\(now().formatted(.iso8601)) \(Self.oneLine(line))\n"
        let bytes = Array(text.utf8)
        try PrivateFile.createDirectoryIfMissing(directory)
        if let size = Self.size(of: file), size > 0, size + bytes.count > limit {
            guard rename(file.path, rotated.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The last `n` lines, oldest first, across `hook.1.log` and `hook.log`.
    public func tail(_ n: Int) -> [String] {
        guard n > 0 else { return [] }
        let lines = [rotated, file].flatMap { url -> [String] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        return Array(lines.suffix(n))
    }

    /// Both files' size in bytes.
    public var size: Int { (Self.size(of: rotated) ?? 0) + (Self.size(of: file) ?? 0) }

    private static func size(of url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_size)
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
