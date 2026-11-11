import Foundation
import RelayCore

extension IPSReport {
    /// The report at `url`, when it is a file under `maxBytes` that parses; nil otherwise.
    public static func read(_ url: URL, binary: String = "Hook") -> IPSReport? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        return try? parse(data, binary: binary)
    }

    /// The newest `<binary>-*.ips` in `dir` changed after `after`.
    public static func newest(in dir: URL, after: Date, binary: String = "Hook") -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let candidates = names.filter { $0.hasPrefix("\(binary)-") && $0.hasSuffix(".ips") }.compactMap { name -> (URL, Date)? in
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  date > after else { return nil }
            return (url, date)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// `~/Library/Logs/DiagnosticReports`.
    public static func reportsDirectory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }
}
