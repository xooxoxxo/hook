import Foundation
import RelayCore

/// Runs `<repo>/bin/relay integrations … --json` in the login shell, so PATH and `*_HOME`
/// match what the user's terminal has and the harness CLIs are found. One command at a time:
/// a newer request waits for the one running. stdout and stderr go to two private temp
/// files, so what a login profile prints never mixes with the JSON.
@MainActor public final class IntegrationsRunner {
    /// The configured repo folder, read at each run.
    private let repoPath: () -> String?
    private let serial = SerialTasks()

    public init(repoPath: @escaping () -> String?) {
        self.repoPath = repoPath
    }

    /// The command's stdout on exit 0 or 4, else why there is none.
    public func run(_ command: IntegrationCommand) async -> Result<Data, IntegrationError> {
        let repo = repoPath()
        return await serial.run { await Self.execute(command, repoPath: repo) }
    }

    /// `run(.status)`, decoded.
    public func status() async -> Result<IntegrationStatus, IntegrationError> {
        switch await run(.status) {
        case .success(let data):
            guard let status = try? IntegrationStatus.decode(data) else { return .failure(.unreadable) }
            return .success(status)
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func execute(_ command: IntegrationCommand, repoPath: String?) async -> Result<Data, IntegrationError> {
        let fm = FileManager.default
        guard let repoPath, let relay = IntegrationCommand.relayPath(repoPath: repoPath),
              fm.isExecutableFile(atPath: relay) else { return .failure(.notInstalled) }
        let folder = fm.temporaryDirectory.appending(path: "hook-integrations-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.failed(UserFacingError.text(error)))
        }
        defer { try? fm.removeItem(at: folder) }
        let out = folder.appending(path: "stdout.json"), err = folder.appending(path: "stderr.txt")
        let line = command.shellLine(repoPath: repoPath, stdout: out.path, stderr: err.path)
        let outcome = await LoginShell.run(line, timeout: command.timeout)
        let stdout = (try? Data(contentsOf: out)) ?? Data()
        let stderr = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        let result = IntegrationOutcome.interpret(status: outcome.status, timedOut: outcome.timedOut, stdout: stdout,
                                                  stderr: stderr, shellOutput: outcome.output)
        if case .failure(let error) = result {
            HookLog.error("Integrations", "\(command.arguments.first ?? "?") failed: \(error.text)")
        }
        return result
    }
}
