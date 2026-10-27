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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = Once()
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let outcome = Outcome(status: finished.terminationStatus, output: buffer.text,
                                      timedOut: once.timedOut)
                if once.claim() { continuation.resume(returning: outcome) }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                if once.claim() {
                    continuation.resume(returning: Outcome(status: -1, output: error.localizedDescription, timedOut: false))
                }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                once.markTimedOut()
                process.terminate()
            }
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

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var didTimeOut = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }
}
