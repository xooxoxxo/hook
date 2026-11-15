import Foundation

/// Safe context for a failed Pond load. Error descriptions and userInfo text may
/// contain endpoints or credentials; only fixed labels and numeric codes are logged.
enum PondTransportDiagnostics {
    static func message(for error: URLError) -> String {
        guard error.code == .notConnectedToInternet else { return error.localizedDescription }
        return "Couldn't reach Pond. Check your connection and, for a local Pond, Hook's Local Network access. Then try again."
    }

    static func logMessage(for error: URLError) -> String? {
        guard error.code != .cancelled else { return nil }
        var fields = ["URLError \(error.code.rawValue)"]
        var current: NSError? = error as NSError
        var previous = (domain: NSURLErrorDomain, code: error.code.rawValue)
        var underlying: [String] = []
        var network: String?
        // Bound both traversal and output, including malformed or cyclic chains.
        for depth in 0..<6 {
            guard let cause = current else { break }
            if network == nil, cause.domain == NSURLErrorDomain,
               let raw = cause.userInfo[NSURLErrorNetworkUnavailableReasonKey] as? NSNumber {
                network = networkLabel(raw.intValue)
            }
            if depth > 0, underlying.count < 3,
               cause.domain != previous.domain || cause.code != previous.code {
                underlying.append("\(domainLabel(cause.domain))(\(cause.code))")
            }
            previous = (cause.domain, cause.code)
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let network { fields.append("network=\(network)") }
        if !underlying.isEmpty { fields.append("underlying=" + underlying.joined(separator: ">")) }
        return "request failed (" + fields.joined(separator: "; ") + ")"
    }

    private static func domainLabel(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain: return "URL"
        case NSPOSIXErrorDomain: return "POSIX"
        case NSCocoaErrorDomain: return "Cocoa"
        case "kCFErrorDomainCFNetwork": return "CFNetwork"
        default: return "other"
        }
    }

    private static func networkLabel(_ value: Int) -> String {
        let reason = URLError.NetworkUnavailableReason(rawValue: value)
        if reason == .cellular { return "cellular" }
        if reason == .expensive { return "expensive" }
        if reason == .constrained { return "constrained" }
        return "other"
    }
}
