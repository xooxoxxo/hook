import RelayUIMac
import AppKit
import RelayCore
import RelayUI
import UserNotifications

/// Notifications for new asks. `NotifyPolicy` decides what to show and
/// when; this class owns the flush timer and talks to UNUserNotificationCenter.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A click on "N new asks" (first nil) or on the away summary (first = the first ask
    /// that arrived while away, selected in the list).
    var onOpenList: (@MainActor (_ first: String?) -> Void)?
    /// Authorization was requested in this run (Welcome, Settings or before the first post).
    private var requested = false
    var onOpenClosed: (@MainActor (String) -> Void)?
    private var closedRequests: [String: Date] = [:]
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
        // macOS 27 calls this handler on a libdispatch worker. Written plainly here it was
        // inferred main-actor isolated, and Swift's isolation check trapped (0.12, every
        // Settings open and every crash offer). `@Sendable` makes it nonisolated (CallbackHop).
        let raw: Int = await CallbackHop.value { done in
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable current in
                done(current.authorizationStatus.rawValue)
            }
        }
        return NotificationPermission(raw)
    }

    /// True only when the owner turned Hook's notifications off in System Settings.
    /// Kept for the current Notifications tab until its redesign reads `permission()`.
    func authorizationDenied() async -> Bool {
        await permission() == .denied
    }

    /// Before the first notification Hook would post: ask once if never asked.
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
        let made = NotificationContentMaker.awaySummary(
            text, first: first, sound: settings.sound, images: AskNotificationImage.defaultFolder)
        post(made.content, identifier: made.identifier)
    }

    /// One notification after a crash, pointing to the bar in the panel. Only when
    /// notifications are already allowed: a crash never asks for permission.
    func showCrashNotice() {
        guard available, !quiet else { return }
        Task { @MainActor in
            guard await permission() == .authorized else { return }
            let note = NotificationContentMaker.crashNotice()
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "relay.crash", content: note, trigger: nil))
        }
    }

    /// Informational feedback never requests permission or changes the focused window.
    /// Success means the system accepted the request, not that the owner saw its banner.
    func showClosedAsk(_ id: String, canShowClosed: Bool) async -> Bool {
        guard available, !quiet, await permission() == .authorized else { return false }
        let now = Date()
        closedRequests = closedRequests.filter { now.timeIntervalSince($0.value) < 3 }
        if closedRequests[id] != nil { return true }
        closedRequests[id] = now
        let note = NotificationContentMaker.closedAsk(id: id, canShowClosed: canShowClosed)
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "hook.closed." + id, content: note, trigger: nil))
            return true
        } catch {
            closedRequests.removeValue(forKey: id)
            return false
        }
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
        // One new ask or "N new asks": both carry the fish on the hook (AskNotificationImage).
        let made = NotificationContentMaker.asks(
            content, sound: settings.sound, images: AskNotificationImage.defaultFolder)
        post(made.content, identifier: made.identifier)
    }

    /// No category, so no action buttons. Inside the Task, `add(_:)` resolves to
    /// its `async throws` overload; a refused post (permission denied) is dropped.
    /// A posted attachment's file is moved into the notification store; a refused
    /// post leaves its copy behind, so it is removed here.
    private func post(_ note: UNMutableNotificationContent, identifier: String) {
        let copies = note.attachments.map(\.url)
        Task { @MainActor in
            await authorizeIfNeeded()
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: note, trigger: nil))
            for url in copies { try? FileManager.default.removeItem(at: url) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["id"] as? String
        let first = response.notification.request.content.userInfo["first"] as? String
        let closed = response.notification.request.content.userInfo["closedId"] as? String
        completionHandler()
        Task { @MainActor in
            if let closed { self.onOpenClosed?(closed) }
            else if let id { self.onOpen(id) } else { self.onOpenList?(first) }
        }
    }

    /// Show banners while Hook is frontmost too (e.g. Settings is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
