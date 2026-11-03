import Foundation

/// The few fields Hook reads from a macOS crash report (`.ips`): the exception, its signal,
/// the termination reason, and the crashed thread's top frames in Hook's own binary. The rest
/// of the file (paths, other threads, images, registers) is never kept.
public struct IPSReport: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        /// The symbol name, nil when the report isn't symbolicated.
        public var symbol: String?
        /// The offset into the symbol (`symbolLocation`).
        public var offset: Int?
        /// The offset into Hook's image.
        public var imageOffset: Int

        public init(symbol: String?, offset: Int?, imageOffset: Int) {
            self.symbol = symbol
            self.offset = offset
            self.imageOffset = imageOffset
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case notIPS
        case noException
    }

    public var exception: String
    public var signal: String?
    public var termination: String?
    /// The crashed thread's frames in Hook's own image, top first, at most 8.
    public var appFrames: [Frame]

    public init(exception: String, signal: String?, termination: String?, appFrames: [Frame]) {
        self.exception = exception
        self.signal = signal
        self.termination = termination
        self.appFrames = appFrames
    }

    public static let frameLimit = 8

    /// Every app frame has a symbol.
    public var symbolicated: Bool { !appFrames.isEmpty && appFrames.allSatisfy { $0.symbol != nil } }

    /// A JSON header line, then the JSON body.
    public static func parse(_ data: Data, binary: String = "Hook") throws -> IPSReport {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { throw ParseError.notIPS }
        let header = data[data.startIndex..<newline]
        let rest = data[data.index(after: newline)...]
        guard (try? JSONSerialization.jsonObject(with: header)) is [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: rest)) as? [String: Any]
        else { throw ParseError.notIPS }
        guard let exception = body["exception"] as? [String: Any],
              let type = exception["type"] as? String, !type.isEmpty
        else { throw ParseError.noException }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let own = Set(images.indices.filter { images[$0]["name"] as? String == binary })
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let crashed: [String: Any]? = {
            if let index = body["faultingThread"] as? Int, threads.indices.contains(index) { return threads[index] }
            return threads.first { $0["triggered"] as? Bool == true }
        }()
        let frames = ((crashed?["frames"] as? [[String: Any]]) ?? []).compactMap { frame -> Frame? in
            guard let image = frame["imageIndex"] as? Int, own.contains(image) else { return nil }
            let symbol = (frame["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Frame(symbol: symbol, offset: frame["symbolLocation"] as? Int,
                         imageOffset: (frame["imageOffset"] as? Int) ?? 0)
        }

        return IPSReport(exception: type, signal: exception["signal"] as? String,
                         termination: termination(body["termination"] as? [String: Any]),
                         appFrames: Array(frames.prefix(frameLimit)))
    }

    private static func termination(_ t: [String: Any]?) -> String? {
        guard let t else { return nil }
        if let indicator = t["indicator"] as? String, !indicator.isEmpty { return indicator }
        guard let namespace = t["namespace"] as? String else { return nil }
        if let code = t["code"] as? Int { return "\(namespace) \(code)" }
        return namespace
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
