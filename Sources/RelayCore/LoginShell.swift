import Foundation

/// Runs one command in the user's login shell, off the main actor, with a time cap.
/// The setup window registers the MCP server this way: a GUI app's PATH lacks what the
/// login shell adds. stdin is /dev/null, so a prompt can't hang it.
public enum LoginShell {
    public struct Outcome: Equatable, Sendable {
        public var status: Int32
        /// stdout and stderr together, trimmed.
        public var output: String
        public var timedOut: Bool
        public init(status: Int32, output: String, timedOut: Bool) {
            self.status = status
            self.output = output
            self.timedOut = timedOut
        }
        public var ok: Bool { status == 0 && !timedOut }
    }

    public static let defaultTimeout: TimeInterval = 30

    /// `$SHELL` when it is an absolute path, else /bin/zsh.
    public static func shell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }

    public static func run(_ command: String, shell: String = LoginShell.shell(),
                           timeout: TimeInterval = defaultTimeout) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            Run(continuation: continuation).start(command: command, shell: shell, timeout: timeout)
        }
    }

    /// The one line the setup window shows for a failed run.
    public static func failureLine(_ outcome: Outcome) -> String {
        if outcome.timedOut { return "No answer within \(Int(defaultTimeout)) seconds" }
        if outcome.status == 127 { return "The claude command wasn't found" }
        let last = outcome.output.split(separator: "\n").last.map(String.init) ?? ""
        return last.isEmpty ? "It stopped with status \(outcome.status)" : Sanitize.revealLine(last)
    }
}

/// One run of the shell. The shell starts as the leader of its own process group, so a
/// timeout can stop everything it started, and the result is delivered exactly once:
/// - the shell exits and the pipe reaches end of file: its status and output;
/// - the shell exits but something it left behind still holds the pipe: its status and
///   the output so far, after a short grace (that leftover is not killed);
/// - the deadline passes with the shell still running: the group gets SIGTERM, then
///   SIGKILL, and the result is a timeout with the output so far, without waiting on it.
private final class Run: @unchecked Sendable {
    /// How long to keep reading after the shell exits while the pipe is still open.
    static let drainGrace: TimeInterval = 0.25
    /// Between SIGTERM and SIGKILL on a timeout.
    static let killGrace: TimeInterval = 1

    private let lock = NSLock()
    private var continuation: CheckedContinuation<LoginShell.Outcome, Never>?
    private var data = Data()
    private var exitStatus: Int32?
    private var atEOF = false
    private var reader: FileHandle?

    init(continuation: CheckedContinuation<LoginShell.Outcome, Never>) {
        self.continuation = continuation
    }

    func start(command: String, shell: String, timeout: TimeInterval) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return failToStart(errno) }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = its pid); every other descriptor closed in the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), strdup("-c"), strdup(command), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var spawnedPID: pid_t = 0
        let spawned = posix_spawn(&spawnedPID, shell, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return failToStart(spawned)
        }
        let child = spawnedPID

        let handle = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
        lock.lock()
        reader = handle
        lock.unlock()
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            lock.lock()
            if chunk.isEmpty { atEOF = true } else { data.append(chunk) }
            let done = chunk.isEmpty && exitStatus != nil
            lock.unlock()
            if chunk.isEmpty { handle.readabilityHandler = nil }
            if done { finish(timedOut: false) }
        }
        DispatchQueue.global().async { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
            let status = Self.decode(raw)
            lock.lock()
            exitStatus = status
            let done = atEOF
            lock.unlock()
            if done { return finish(timedOut: false) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { [self] in
                finish(timedOut: false)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            let running = exitStatus == nil && continuation != nil
            lock.unlock()
            guard running else { return }
            kill(-child, SIGTERM)
            finish(timedOut: true)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                kill(-child, SIGKILL)
            }
        }
    }

    private func failToStart(_ code: Int32) {
        let message = String(cString: strerror(code))
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: .init(status: -1, output: message, timedOut: false))
    }

    private func finish(timedOut: Bool) {
        lock.lock()
        guard let pending = continuation else { return lock.unlock() }
        continuation = nil
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = exitStatus ?? 128 + SIGTERM
        let handle = reader
        lock.unlock()
        handle?.readabilityHandler = nil
        pending.resume(returning: .init(status: status, output: output, timedOut: timedOut))
    }

    /// waitpid's status as Process reports it: the exit code, or 128 + the signal.
    static func decode(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }
}
