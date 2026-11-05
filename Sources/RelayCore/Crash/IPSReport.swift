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

    /// A report bigger than this isn't read: real ones are a few hundred KB.
    public static let maxBytes = 8 * 1024 * 1024
    /// JSON nested deeper than this isn't parsed; a real report nests about 8 deep.
    public static let maxDepth = 64
    /// Only this many of the crashed thread's frames are looked at.
    static let frameScanLimit = 512

    /// A JSON header line, then the JSON body. Anything that doesn't fit throws, whatever
    /// shape a newer macOS gives it: a report is never trusted to be well formed.
    public static func parse(_ data: Data, binary: String = "Hook") throws -> IPSReport {
        guard data.count <= maxBytes, nestingDepth(data) <= maxDepth else { throw ParseError.notIPS }
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
        let frames = ((crashed?["frames"] as? [Any]) ?? []).prefix(frameScanLimit).compactMap { item -> Frame? in
            guard let frame = item as? [String: Any] else { return nil }
            guard let image = frame["imageIndex"] as? Int, own.contains(image) else { return nil }
            let symbol = (frame["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Frame(symbol: symbol.map { String($0.prefix(512)) }, offset: frame["symbolLocation"] as? Int,
                         imageOffset: (frame["imageOffset"] as? Int) ?? 0)
        }

        return IPSReport(exception: String(type.prefix(128)), signal: (exception["signal"] as? String).map { String($0.prefix(64)) },
                         termination: termination(body["termination"] as? [String: Any]),
                         appFrames: Array(frames.prefix(frameLimit)))
    }

    /// The deepest `[` / `{` nesting outside strings, counted in one pass with no recursion.
    static func nestingDepth(_ data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > deepest { deepest = depth }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth = max(0, depth - 1)
            default: break
            }
        }
        return deepest
    }

    private static func termination(_ t: [String: Any]?) -> String? {
        guard let t else { return nil }
        if let indicator = t["indicator"] as? String, !indicator.isEmpty { return String(indicator.prefix(200)) }
        guard let namespace = (t["namespace"] as? String).map({ String($0.prefix(64)) }) else { return nil }
        if let code = t["code"] as? Int { return "\(namespace) \(code)" }
        return namespace
    }

}
