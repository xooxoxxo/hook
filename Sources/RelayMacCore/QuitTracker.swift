import AppKit
import Darwin
import RelayCore

/// The sender of the last SIGTERM (slot 0) and SIGHUP (slot 1), written by the C handler and
/// read on the main queue. Set up before the handler is installed; the handler only stores
/// an Int32, which is async-signal-safe.
nonisolated(unsafe) private let signalSenders: UnsafeMutablePointer<Int32> = {
    let slots = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
    slots.initialize(repeating: 0, count: 2)
    return slots
}()

/// `sigaction` with SA_SIGINFO: records who sent the signal. The quit itself runs from the
/// dispatch source, which kqueue fires for the same signal.
private func recordSignalSender(_ signo: Int32, _ info: UnsafeMutablePointer<__siginfo>?,
                                _ context: UnsafeMutableRawPointer?) {
    guard let info else { return }
    signalSenders[signo == SIGHUP ? 1 : 0] = info.pointee.si_pid
}

/// Why this run is quitting, for `hook.log` and the run marker. Each place in Hook that quits
/// says why (`terminate(_:)`); a signal or a quit Apple event is read when it comes; anything
/// left over is a terminate from code no one tagged.
@MainActor public final class QuitTracker {
    public static let shared = QuitTracker()

    /// What a call site, a signal or the installer said, before AppKit asks.
    public private(set) var pending: QuitCause?
    /// Fixed once `applicationShouldTerminate` has looked at the Apple event.
    public private(set) var resolved: QuitCause?
    private var poweringOff = false
    private var sources: [any DispatchSourceSignal] = []
    private var powerObserver: (any NSObjectProtocol)?

    /// The cause the quit is logged and marked with.
    public var cause: QuitCause { resolved ?? pending ?? .code("terminate") }

    /// Quits Hook for `cause`, through AppKit (held closes are sent first).
    public func terminate(_ cause: QuitCause) {
        if pending == nil { pending = cause }
        NSApp.terminate(nil)
    }

    /// Leaves without AppKit's quit (a second copy before it set anything up): the line first.
    public func exit(_ cause: QuitCause, code: Int32 = 0) -> Never {
        HookLog.record(.quit(clean: true, cause: cause))
        Darwin.exit(code)
    }

    /// SIGTERM and SIGHUP become a quit through AppKit, logged with their sender (or with the
    /// installer or updater, when install.sh left a quit request first). `onSignal` runs on
    /// the main queue before the quit.
    public func watchSignals(dataDirectory: URL, onSignal: @escaping @MainActor () -> Void) {
        _ = signalSenders.pointee   // set up before any handler can touch it
        for (signo, name) in [(SIGTERM, "TERM"), (SIGHUP, "HUP")] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = recordSignalSender
            action.sa_flags = SA_SIGINFO
            sigemptyset(&action.sa_mask)
            if sigaction(signo, &action, nil) != 0 { signal(signo, SIG_IGN) }
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            source.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let slot = signo == SIGHUP ? 1 : 0
                    let sender = signalSenders[slot]
                    signalSenders[slot] = 0
                    self.signalled(name, sender: sender, dataDirectory: dataDirectory)
                    onSignal()
                    // terminate(_:) waits in a nested event loop while held closes are sent. Inside
                    // this main-queue handler that loop can't run main-queue work, so the send never
                    // finished and Hook never quit; from a run-loop block it can.
                    RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
                }
            }
            source.resume()
            sources.append(source)
        }
        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
    }

    private func signalled(_ name: String, sender: Int32, dataDirectory: URL) {
        guard pending == nil else { return }
        let pid = sender > 0 ? sender : nil
        if let request = QuitRequest.take(dataDirectory: dataDirectory), request.isFresh(now: Date()) {
            var cause = request.cause
            if cause.pid == nil { cause.pid = pid }
            pending = cause
        } else {
            pending = .signal(name, pid: pid, process: pid.flatMap(Self.processName))
        }
    }

    /// `applicationShouldTerminate`: a cause already set wins; else the quit Apple event (its
    /// logout, restart or shutdown reason, or the app that sent it); else macOS's power-off
    /// notice; else a terminate from code.
    public func resolve() {
        guard resolved == nil else { return }
        if let pending {
            resolved = pending
        } else if let event = NSAppleEventManager.shared().currentAppleEvent,
                  event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) {
            let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)).map { descriptor in
                descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
            }
            let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
            let sender = pid.flatMap { $0 > 0 ? $0 : nil }
            var cause = QuitCause.appleEvent(reason: reason.flatMap { $0 == 0 ? nil : $0 }, senderPID: sender,
                                             sender: sender.flatMap(Self.processName))
            if cause.kind == .appleEvent, poweringOff { cause = QuitCause(.powerOff) }
            resolved = cause
        } else if poweringOff {
            resolved = QuitCause(.powerOff)
        } else {
            resolved = .code("terminate")
        }
    }

    /// The app's name, else the kernel's short process name; nil when the process is gone.
    public static func processName(_ pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }
}
