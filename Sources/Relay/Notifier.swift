import AppKit
import RelayCore
import UserNotifications

/// Notifications for new asks. `NotifyPolicy` decides what to show and
/// when; this class owns the flush timer and talks to UNUserNotificationCenter.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Clicking an "N new asks" notification, which names no single ask.
    var onOpenList: (@MainActor () -> Void)?
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

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// True only when the owner turned Relay's notifications off in System Settings.
    func authorizationDenied() async -> Bool {
        guard available else { return false }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { current in
                continuation.resume(returning: current.authorizationStatus == .denied)
            }
        }
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
    /// away"). It names no ask, so a click opens the list.
    func showReturnSummary(_ text: String, settings: NotifySettings) {
        guard available, !quiet else { return }
        let note = UNMutableNotificationContent()
        note.title = "Relay"
        note.body = text
        note.threadIdentifier = "relay"
        if settings.sound { note.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "relay.away.\(UUID().uuidString)", content: note, trigger: nil))
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
        let identifier: String
        switch content {
        case let .single(id, project, title):
            note.title = Sanitize.revealLine(project)
            note.body = Sanitize.revealLine(title)
            note.threadIdentifier = project
            note.userInfo = ["id": id]
            identifier = id
        case .many(let count):
            note.title = "Relay"
            note.body = "\(count) new asks"
            note.threadIdentifier = "relay"
            identifier = "relay.many.\(UUID().uuidString)"
        }
        if settings.sound { note.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: note, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["id"] as? String
        completionHandler()
        Task { @MainActor in
            if let id { self.onOpen(id) } else { self.onOpenList?() }
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
