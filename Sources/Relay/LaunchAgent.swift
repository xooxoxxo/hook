import Foundation
import RelayCore

/// Launch at login: the same LaunchAgent plist that install.sh
/// writes. Toggling only writes or removes the file, with no launchctl, so the running
/// app is never stopped; launchd reads the file at the next login.
enum LaunchAgent {
    static let label = "io.github.xooxoxxo.relay"

    /// Under $HOME, so a manual check can point HOME at a temp folder.
    static var plistURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Label, `/usr/bin/open -a <app>`, RunAtLoad true, KeepAlive false: install.sh's keys.
    static func plistData(appPath: String) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// A plain 0644 file, like install.sh's. Not a private file: `PrivateFile` would
    /// chmod ~/Library/LaunchAgents to 0700. The folder is created with default
    /// permissions only when it's missing, and never chmodded.
    static func install(appPath: String) throws {
        let data = try plistData(appPath: appPath)
        let directory = plistURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
    }

    static func remove() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(at: plistURL)
    }
}
