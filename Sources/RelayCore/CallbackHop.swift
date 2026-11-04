import Foundation

/// Awaits a completion-handler API whose callback may run on any queue.
///
/// A closure written inside a `@MainActor` type and handed to an Objective-C API that doesn't
/// mark its handler `@Sendable` is inferred main-actor isolated, so Swift checks the executor
/// when it runs. macOS 27 calls `UNUserNotificationCenter.getNotificationSettings`' handler on
/// a libdispatch worker, and that check traps (`_dispatch_assert_queue_fail`): Hook 0.12 died
/// opening Settings and offering a crash. Here the handler is `@Sendable` and nonisolated, and
/// the caller gets the value back on its own actor.
///
///     let raw: Int = await CallbackHop.value { done in
///         UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
///             done(settings.authorizationStatus.rawValue)
///         }
///     }
///
/// Every closure passed to such an API in Hook is `@Sendable` (or nonisolated);
/// `CallbackIsolationTests` checks the sources for it.
public enum CallbackHop {
    public static func value<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ start: (@escaping @Sendable (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation(isolation: isolation) { (continuation: CheckedContinuation<T, Never>) in
            start { @Sendable value in continuation.resume(returning: value) }
        }
    }
}
