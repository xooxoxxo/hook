import Foundation
import Network
import os
import RelayCore

/// Feeds one Pond client's request outcomes to `LocalNetworkGate`, with whether the Pond's
/// address is on the local network (resolved once, off the main thread) and whether the Mac
/// is online (`NWPathMonitor`). `onChange` runs on the main actor.
final class LocalNetworkMonitor: Sendable {
    private struct State: Sendable {
        var gate = LocalNetworkGate()
        var pondIsLocal: Bool?
        var online = true
    }

    private let host: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let path = NWPathMonitor()
    private let onChange: @MainActor @Sendable (LocalNetworkGate.Change) -> Void

    init(url: URL, onChange: @escaping @MainActor @Sendable (LocalNetworkGate.Change) -> Void) {
        host = url.host() ?? ""
        self.onChange = onChange
        path.pathUpdateHandler = { [state] update in
            state.withLock { $0.online = update.status == .satisfied }
        }
        path.start(queue: DispatchQueue(label: "hook.local-network"))
    }

    deinit { path.cancel() }

    /// `MailboxClient`'s `onOutcome`.
    func record(_ outcome: PondOutcome) {
        let local = state.withLock { $0.pondIsLocal } ?? {
            let resolved = LocalAddress.isLocal(host: host, resolved: LocalAddress.resolve(host))
            state.withLock { $0.pondIsLocal = resolved }
            return resolved
        }()
        let change = state.withLock { $0.gate.record(outcome, pondIsLocal: local, internetUp: $0.online) }
        guard let change else { return }
        let onChange = onChange
        Task { @MainActor in onChange(change) }
    }
}
