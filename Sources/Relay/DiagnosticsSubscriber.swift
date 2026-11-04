import Foundation
import MetricKit
import RelayCore

/// MetricKit's diagnostic payloads (macOS 12+): each crash, hang, CPU or disk-write exception
/// macOS reports for Hook becomes one `hook.log` line (`MetricDiagnostics`).
/// macOS delivers them on its own schedule, at most about once a day, on a background queue.
final class DiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsSubscriber()

    /// Only inside an app bundle, like the notification center.
    func start() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for event in Self.events(payload) { HookLog.record(event) }
        }
    }

    static func events(_ payload: MXDiagnosticPayload) -> [HookLog.Event] {
        var events: [HookLog.Event] = []
        for crash in payload.crashDiagnostics ?? [] {
            events.append(MetricDiagnostics.crash(
                exceptionType: crash.exceptionType?.intValue, exceptionCode: crash.exceptionCode?.intValue,
                signal: crash.signal?.intValue, reason: crash.terminationReason,
                version: crash.metaData.applicationBuildVersion))
        }
        for hang in payload.hangDiagnostics ?? [] {
            events.append(MetricDiagnostics.hang(seconds: hang.hangDuration.converted(to: .seconds).value,
                                                 version: hang.metaData.applicationBuildVersion))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            events.append(MetricDiagnostics.cpuException(
                cpuSeconds: cpu.totalCPUTime.converted(to: .seconds).value,
                sampledSeconds: cpu.totalSampledTime.converted(to: .seconds).value,
                version: cpu.metaData.applicationBuildVersion))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            events.append(MetricDiagnostics.diskWrites(megabytes: disk.totalWritesCaused.converted(to: .megabytes).value,
                                                       version: disk.metaData.applicationBuildVersion))
        }
        return events
    }
}
