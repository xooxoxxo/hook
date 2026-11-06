import Foundation
import LocalAuthentication

/// Proof that the owner is at the Mac before Hook accepts a changed command, link or file, or
/// trusts a restored Pond's history. Behind a protocol so the Store's tests can fake it (they
/// fake `PanelShellActions.confirmPresence`, which the app sets from this).
public protocol PresenceCheck: Sendable {
    func confirm(reason: String) async -> Bool
}

/// Touch ID, else the login password: `.deviceOwnerAuthentication` falls back to it, so it
/// also works over screen sharing. A script that drives Hook's window can't answer it.
public struct UserPresence: PresenceCheck {
    public init() {}
    public func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
