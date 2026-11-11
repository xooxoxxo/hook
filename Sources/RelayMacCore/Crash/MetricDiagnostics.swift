import RelayCore
import Foundation

/// MetricKit's diagnostic payloads (crashes, hangs, CPU and disk-write exceptions), each summed up as one `hook.log` line: numbers and versions only, plus the
/// crash's termination reason, redacted and cut like any other quoted value.
public enum MetricDiagnostics {
    public static func crash(exceptionType: Int?, exceptionCode: Int?, signal: Int?, reason: String?,
                             version: String?) -> HookLog.Event {
        var parts: [String] = []
        if let exceptionType { parts.append("exception=\(exceptionType)") }
        if let exceptionCode { parts.append("code=\(exceptionCode)") }
        if let signal { parts.append("signal=\(signal)") }
        parts += versionPart(version)
        if let reason = reason.map(RollingLog.oneLine), !reason.isEmpty {
            parts.append("reason=" + String(reason.prefix(120)))
        }
        return .diagnostic(kind: "crash", detail: parts.joined(separator: " "))
    }

    public static func hang(seconds: Double, version: String?) -> HookLog.Event {
        .diagnostic(kind: "hang", detail: (["duration=" + duration(seconds)] + versionPart(version)).joined(separator: " "))
    }

    public static func cpuException(cpuSeconds: Double, sampledSeconds: Double, version: String?) -> HookLog.Event {
        .diagnostic(kind: "cpu", detail: (["cpu=" + duration(cpuSeconds), "over=" + duration(sampledSeconds)]
            + versionPart(version)).joined(separator: " "))
    }

    public static func diskWrites(megabytes: Double, version: String?) -> HookLog.Event {
        .diagnostic(kind: "disk-writes", detail: (["written=" + String(format: "%.0fMB", megabytes)]
            + versionPart(version)).joined(separator: " "))
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "?" }
        return String(format: "%.1fs", seconds)
    }

    private static func versionPart(_ version: String?) -> [String] {
        guard let version, let safe = SemVer(strict: version) else { return version == nil ? [] : ["version=?"] }
        return ["version=\(safe)"]
    }
}
