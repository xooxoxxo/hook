import AppKit
import RelayCore
import UserNotifications

/// Notifications for new asks. `NotifyPolicy` decides what to show and
/// when; this class owns the flush timer and talks to UNUserNotificationCenter.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A click on "N new asks" (first nil) or on the away summary (first = the first ask
    /// that arrived while away, selected in the list).
    var onOpenList: (@MainActor (_ first: String?) -> Void)?
    /// Authorization was requested in this run (Welcome, Settings or before the first post).
    private var requested = false
    private let onOpen: @MainActor (String) -> Void
    private var policy = NotifyPolicy(settings: NotifySettings())
    private var settings = NotifySettings()
    private var flushTask: Task<Void, Never>?
    /// Away mode: nothing is shown, and a waiting flush is dropped.
    private var quiet = false
    /// UNUserNotificationCenter traps outside an app bundle (e.g. a bare `swift run`).
    private let available = Bundle.main.bundleIdentifier != nil

    init(onOpen: @escaping @MainActor (String) -> Void) {
        self.onOpen = onOpen
        super.init()
        if available { UNUserNotificationCenter.current().delegate = self }
    }

    /// Welcome page 2 and Settings → Notifications → Allow Notifications….
    func requestAuthorization() async {
        guard available else { return }
        requested = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func permission() async -> NotificationPermission {
        guard available else { return .notDetermined }
        let raw = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { current in
                continuation.resume(returning: current.authorizationStatus.rawValue)
            }
        }
        return NotificationPermission(raw)
    }

    /// True only when the owner turned Relay's notifications off in System Settings.
    /// Kept for the current Notifications tab until its redesign reads `permission()`.
    func authorizationDenied() async -> Bool {
        await permission() == .denied
    }

    /// Before the first notification Relay would post: ask once if never asked.
    private func authorizeIfNeeded() async {
        guard NotificationAuth.shouldRequest(status: await permission(), requestedBefore: requested) else { return }
        await requestAuthorization()
    }

    /// Clears banners and queued requests for asks that closed, left or reopened.
    func remove(ids: Set<String>) {
        guard available, !ids.isEmpty else { return }
        let list = Array(ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: list)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: list)
    }

    /// New asks from the Store diff. The Store never reports its first load or a
    /// source swap, so those never notify.
    func handle(newItems: [WireItem], settings: NotifySettings) {
        self.settings = settings
        policy.update(settings: settings)
        perform(policy.add(newItems, now: Date()))
    }

    /// Away mode on or off. Going quiet cancels a waiting flush and returns how
    /// many asks it held, so they can join the away count instead of vanishing.
    @discardableResult
    func setQuiet(_ on: Bool) -> Int {
        guard quiet != on else { return 0 }
        quiet = on
        guard on else { return 0 }
        flushTask?.cancel()
        flushTask = nil
        let dropped = policy.pendingCount
        policy = NotifyPolicy(settings: settings)
        return dropped
    }

    /// The one notification on return from away ("3 asks arrived while you were
    /// away"). A click opens the list with `first`, the first ask that arrived, selected.
    func showReturnSummary(_ text: String, first: String?, settings: NotifySettings) {
        guard available, !quiet else { return }
        let note = UNMutableNotificationContent()
        note.title = "Relay"
        note.body = text
        note.threadIdentifier = "relay"
        note.userInfo = first.map { ["first": $0] } ?? [:]
        if settings.sound { note.sound = .default }
        post(note, identifier: "relay.away.\(UUID().uuidString)")
    }

    private func perform(_ action: NotifyAction) {
        switch action {
        case .none:
            break
        case .show(let content):
            deliver(content)
        case .scheduleFlush(let date):
            scheduleFlush(at: date)
        }
    }

    private func scheduleFlush(at date: Date) {
        flushTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            let action = self.policy.flush(now: Date())
            self.perform(action)
        }
    }

    private func deliver(_ content: NotifyContent) {
        guard available, !quiet else { return }
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        let identifier: String
        switch content {
        case let .single(id, project, _):
            note.threadIdentifier = project.isEmpty ? "relay" : project
            note.userInfo = ["id": id]
            identifier = id
        case .many:
            note.threadIdentifier = "relay"
            identifier = "relay.many.\(UUID().uuidString)"
        }
        if settings.sound { note.sound = .default }
        post(note, identifier: identifier)
    }

    /// No category, so no action buttons. Inside the Task, `add(_:)` resolves to
    /// its `async throws` overload; a refused post (permission denied) is dropped.
    private func post(_ note: UNMutableNotificationContent, identifier: String) {
        Task { @MainActor in
            await authorizeIfNeeded()
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: note, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["id"] as? String
        let first = response.notification.request.content.userInfo["first"] as? String
        completionHandler()
        Task { @MainActor in
            if let id { self.onOpen(id) } else { self.onOpenList?(first) }
        }
    }

    /// Show banners while Relay is frontmost too (e.g. Settings is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
