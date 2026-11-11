import Foundation
import RelayCore

extension IntegrationCommand {
    /// What the login shell runs: every word single-quoted, stdout and stderr into the two
    /// files, so what a login profile prints never mixes with the JSON.
    public func shellLine(repoPath: String, stdout: String, stderr: String) -> String {
        let relay = Self.relayPath(repoPath: repoPath) ?? ConnectInfo.normalized(repoPath) + "/bin/relay"
        return Shell.quote(relay) + " integrations " + arguments.map(Shell.quote).joined(separator: " ")
            + " >" + Shell.quote(stdout) + " 2>" + Shell.quote(stderr)
    }
}
