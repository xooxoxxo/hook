import Foundation

/// Where every Keychain call Hook makes runs: a serial queue, never the main thread.
///
/// Under ad-hoc signing each build is a new app to the Keychain, so the first read after an
/// update shows a password prompt, and the call doesn't return until the owner answers it
/// (0.13.1 froze at launch on that). On this queue a prompt holds only the calls behind it:
/// the panel, the menu bar, the local server and the queue keep running, and one prompt is
/// shown at a time. It is a dispatch queue rather than a task, so a prompt nobody answers
/// never holds a thread of Swift's cooperative pool.
public struct KeychainQueue: Sendable {
    /// The app's one queue. Tests that hold a read give their own, so a held read never
    /// stalls another test's Keychain calls.
    public static let shared = KeychainQueue(label: "io.github.xooxoxxo.relay.keychain")

    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// `body` on this queue; its result or its error comes back to the caller.
    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// `body` on this queue, for a call that can't fail.
    public func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
