import Foundation
import RelayCore

/// The launch check: reads the newest Hook crash report after the last run's start.
public enum CrashFinder {
    /// A garbled or missing report still counts as a crash, with no report.
    public static func find(previous: RunMarker, reports: URL, macOS: String, cpu: String) -> CrashSummary {
        var report: IPSReport?
        var when = previous.started
        let file = IPSReport.newest(in: reports, after: previous.started)
        if let url = file {
            report = IPSReport.read(url)
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                when = date
            }
        }
        return CrashSummary(report: report, hookVersion: previous.version, macOS: macOS, cpu: cpu, when: when,
                            reportFile: file, run: previous.started)
    }
}
