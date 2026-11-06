import Foundation

/// Lexical path checks shared by file rows; never accesses the filesystem.
public enum FilePath {
    /// The lexical part of `NSString.standardizingPath`, without the filesystem: "//" and
    /// "." collapse, ".." drops the component before it (never above "/"), a trailing "/"
    /// goes. Expand "~" first.
    public static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// /net, /Network or /home (in any case, as the disk ignores case), also behind "//",
    /// /private, /private/var/automount, /var/automount or /System/Volumes/Data: the
    /// validator's N1 rule, with the prefixes stripped however they are stacked. Lexical.
    public static func isNetwork(_ path: String) -> Bool {
        path.hasPrefix("/") && Validator.isNetworkPath(path)
    }

    /// The first folder starts with "." (/.vol, /.nofollow, /.resolve): the validator's N2
    /// rule. Such roots reach files by id or skip the checks a path gets. Lexical.
    public static func isHiddenRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let first = path.split(separator: "/").first else { return false }
        return first.hasPrefix(".")
    }

    /// The first folder isn't plain ASCII: the validator's N3 rule (the disk's case folding
    /// turns "ſystem", "Syﬆem" or the Kelvin sign into ASCII names). Lexical.
    public static func isNonASCIIRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let first = path.unicodeScalars.split(separator: "/").first else { return false }
        return !first.allSatisfy(\.isASCII)
    }

    /// Never touched: a network path, a hidden root or a non-ASCII first folder. Lexical.
    public static func isUntouchable(_ path: String) -> Bool {
        isHiddenRoot(path) || isNonASCIIRoot(path) || isNetwork(path)
    }

}
