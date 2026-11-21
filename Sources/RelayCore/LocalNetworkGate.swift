import Foundation

/// What one Pond request came to, for `LocalNetworkGate`: an HTTP answer, or the URLError
/// code it failed with.
public enum PondOutcome: Sendable, Equatable {
    case answered
    case failed(URLError.Code)
}

/// A Pond on the local network that keeps timing out while the Mac is online is most likely
/// macOS's Local Network privacy refusing this copy of Hook (a new copy needs its own consent).
/// Pure: the caller says whether the Pond is local and the internet is up, and posts or
/// withdraws the Notice on the change it gets back. It says so once until something changes.
public struct LocalNetworkGate: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case blocked, cleared }

    /// Failures in a row before the Notice shows.
    public static let threshold = 3
    /// The failures Local Network privacy gives: a timeout, "not connected", or "can't connect".
    public static let codes: Set<URLError.Code> = [.timedOut, .notConnectedToInternet, .cannotConnectToHost]

    public private(set) var failures = 0
    public private(set) var blocked = false

    public init() {}

    public mutating func record(_ outcome: PondOutcome, pondIsLocal: Bool, internetUp: Bool) -> Change? {
        switch outcome {
        case .answered:
            failures = 0
            guard blocked else { return nil }
            blocked = false
            return .cleared
        case .failed(let code):
            guard Self.codes.contains(code) else { return nil }
            guard pondIsLocal, internetUp else { failures = 0; return nil }
            failures += 1
            guard failures >= Self.threshold, !blocked else { return nil }
            blocked = true
            return .blocked
        }
    }
}

/// Whether a Pond address is on the local network: a `.local` name, or a private, link-local
/// or unique-local address (as typed, or as the name resolves).
public enum LocalAddress {
    public static func isLocalName(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.hasSuffix(".local") || name == "local"
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16; fc00::/7, fe80::/10.
    public static func isPrivate(_ address: String) -> Bool {
        let text = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        var v6 = in6_addr()
        let bare = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
        }
        return false
    }

    /// The addresses `host` resolves to. Blocking: call it off the main thread.
    public static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var found: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let entry = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(cString: buffer))
            }
            node = entry.pointee.ai_next
        }
        return found
    }

    /// A local name, a private address, or a name that resolves only to private addresses.
    public static func isLocal(host: String, resolved: [String]) -> Bool {
        if isLocalName(host) || isPrivate(host) { return true }
        return !resolved.isEmpty && resolved.allSatisfy(isPrivate)
    }
}
