import AppKit
import RelayCore

/// Collects Save Diagnostics…'s parts off the main actor. Each command runs with a time cap,
/// so a slow `log show` can't hold the file back for long.
enum DiagnosticsCollector {
    static func parts(dataDirectory: URL, home: String, bundleID: String, label: String,
                      version: String) async -> DiagnosticsReport.Parts {
        let lsCopies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
        return await Task.detached {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let cpu = "arm64"
            #else
            let cpu = "x86_64"
            #endif
            let spotlight = run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleID)'"], timeout: 10)
                .components(separatedBy: "\n").filter { $0.hasSuffix(".app") }
            var copies: [String] = []
            for path in lsCopies + spotlight where !copies.contains(path) { copies.append(path) }
            let launchAgent = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 10)
            let systemLog = run("/usr/bin/log", ["show", "--last", DiagnosticsReport.systemLogWindow, "--style", "compact",
                                                 "--predicate", DiagnosticsReport.systemLogPredicate],
                                timeout: DiagnosticsReport.systemLogTimeout)
                .components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("Timestamp") }
            return DiagnosticsReport.Parts(
                hookVersion: version, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", cpu: cpu,
                copies: copies, launchAgent: launchAgent,
                runState: text(RunMarkerStore.url(dataDirectory: dataDirectory)),
                launches: text(LaunchHistory.url(dataDirectory: dataDirectory)),
                hookLog: HookLog.tail(DiagnosticsReport.hookLogLines),
                updateLog: lines(URL(fileURLWithPath: HookLog.updateLogPath(home: home)), DiagnosticsReport.updateLogLines),
                crashFiles: crashFiles(IPSReport.reportsDirectory(home: home)),
                systemLog: systemLog)
        }.value
    }

    /// The file's text, on one line; nil when it's missing.
    private static func text(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024 else { return nil }
        return RollingLog.oneLine(String(decoding: data, as: UTF8.self))
    }

    private static func lines(_ url: URL, _ n: Int) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Array(String(decoding: data.suffix(256 * 1024), as: UTF8.self).split(separator: "\n").suffix(n).map(String.init))
    }

    /// Hook's (and Relay's, before the rename) crash files, newest first: name, date, size.
    private static func crashFiles(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return names.filter { ($0.hasPrefix("Hook") || $0.hasPrefix("Relay")) && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .compactMap { name -> (String, Date)? in
                let attributes = try? fm.attributesOfItem(atPath: dir.appending(path: name).path)
                guard let date = attributes?[.modificationDate] as? Date else { return nil }
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                return ("\(name)  \(formatter.string(from: date))  \(PrivacyLine.sizeText(size))", date)
            }
            .sorted { $0.1 > $1.1 }.prefix(50).map(\.0)
    }

    /// A command's output (stdout and stderr), stopped after `timeout`.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "couldn't run \(path): \(error.localizedDescription)" }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let text = String(decoding: data.suffix(2 * 1024 * 1024), as: UTF8.self)
        return process.terminationReason == .uncaughtSignal ? text + "\n(stopped after \(Int(timeout)) s)" : text
    }
}
