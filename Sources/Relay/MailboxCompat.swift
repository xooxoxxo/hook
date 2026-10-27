import AppKit
import RelayCore
import RelayUI

/// The mailbox compatibility check and Update Mailbox…: keeps the last version check,
/// posts the panel Notice when the mailbox is older or newer than Hook, runs the update
/// command in a terminal, and checks again once it has run.
@MainActor final class MailboxCompat {
    let checker = MailboxChecker()
    weak var store: Store?
    weak var model: AppModel?
    var launcher: SessionLauncher?
    /// The result last posted as a Notice, per source; the same one isn't posted again
    /// unless the owner asks (Check, or a finished update).
    private var noticed: (key: String, compatibility: MailboxCompatibility)?
    /// Watches an Update Mailbox… run: its done file, and the version every 30 s for 10 minutes.
    private var watch: Task<Void, Never>?
    private var watchKey: String?

    init() {
        checker.onResult = { [weak self] check, manual in self?.handle(check, manual: manual) }
        checker.onStart = { [weak self] in self?.publishLine() }
    }

    /// The configured mailbox, when it is the Store's current source.
    private var current: (settings: MailboxSettings, key: String)? {
        guard case .mailbox(let settings)? = model?.config?.resolvedSource() else { return nil }
        let key = SourceKey.mailbox(settings)
        guard store?.sourceKey == key else { return nil }
        return (settings, key)
    }

    var isMailbox: Bool { current != nil }

    /// After every Store change.
    func storeChanged() {
        guard let store else { return }
        if let watchKey, watchKey != store.sourceKey { stopWatch() }
        checker.observe(sourceKey: store.sourceKey, settings: current?.settings, reachable: store.reachable)
        publishLine()
    }

    /// Settings › Queue's Check.
    func checkNow() {
        guard let current else { return }
        Task { @MainActor in
            await self.checker.check(current.settings, sourceKey: current.key, manual: true)
        }
    }

    /// A fresh check for the update pre-check; nil outside mailbox mode.
    func freshCheck() async -> MailboxCheck? {
        guard let current else { return nil }
        return await checker.check(current.settings, sourceKey: current.key, manual: false)
    }

    /// Update Mailbox…: the command in the terminal, or the update guide when none is set.
    func updateMailbox() {
        guard let current else { return }
        guard let command = model?.config?.mailboxUpdateCommand, let launcher else {
            NSWorkspace.shared.open(MailboxProtocol.updateDocsURL)
            return
        }
        if let problem = RunTarget.problem(command: command) {
            store?.post(.mailboxUpdateCommandInvalid(reason: problem))
            return
        }
        let done = launcher.launchDirectory.appending(path: "mailbox-update-\(UUID().uuidString).done")
        let setting = model?.config?.terminal ?? RelayConfig.automaticTerminal
        Task { @MainActor in
            if let reason = await launcher.run(command, doneFile: done, setting: setting) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                self.store?.post(.mailboxUpdateFailed(reason: reason))
                return
            }
            self.startWatch(done: done, settings: current.settings, key: current.key)
        }
    }

    // MARK: Watching an update

    private func startWatch(done: URL, settings: MailboxSettings, key: String) {
        stopWatch()
        watchKey = key
        watch = Task { @MainActor [weak self] in
            let start = Date()
            var polled = start
            while !Task.isCancelled, Date().timeIntervalSince(start) < MailboxCheckSchedule.updateWatchLimit {
                try? await Task.sleep(for: .seconds(MailboxCheckSchedule.doneFilePoll))
                guard let self, !Task.isCancelled else { return }
                if FileManager.default.fileExists(atPath: done.path) {
                    try? FileManager.default.removeItem(at: done)
                    await self.checker.check(settings, sourceKey: key, manual: true)
                    break
                }
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < MailboxCheckSchedule.updatePollLimit,
                   Date().timeIntervalSince(polled) >= MailboxCheckSchedule.updatePollInterval {
                    polled = Date()
                    if await self.checker.check(settings, sourceKey: key, manual: false).compatibility == .ok { break }
                }
            }
            try? FileManager.default.removeItem(at: done)
            if let self, self.watchKey == key { self.watchKey = nil }
        }
    }

    private func stopWatch() {
        watch?.cancel()
        watch = nil
        watchKey = nil
    }

    // MARK: Results

    private func handle(_ check: MailboxCheck, manual: Bool) {
        publishLine()
        guard let store, let compatibility = check.compatibility, store.sourceKey == check.sourceKey else { return }
        switch compatibility {
        case .ok:
            let wasBehind = noticed?.key == check.sourceKey && noticed?.compatibility != .ok
            if watchKey == check.sourceKey || (manual && wasBehind), let level = check.level {
                store.post(.mailboxUpToDate(level: level))
            } else if Self.isCompatibilityNotice(store.notice) {
                store.dismissNotice()
            }
            if watchKey == check.sourceKey { stopWatch() }
            noticed = (check.sourceKey, .ok)
        case .mailboxOlder(let missing):
            if manual || noticed?.key != check.sourceKey || noticed?.compatibility != compatibility {
                store.post(.mailboxOlder(missing: missing))
            }
            noticed = (check.sourceKey, compatibility)
        case .mailboxNewer:
            if manual || noticed?.key != check.sourceKey || noticed?.compatibility != compatibility {
                store.post(.mailboxNewer)
            }
            noticed = (check.sourceKey, compatibility)
        }
    }

    private static func isCompatibilityNotice(_ notice: PanelNotice?) -> Bool {
        switch notice {
        case .mailboxOlder?, .mailboxNewer?: return true
        default: return false
        }
    }

    private func publishLine() {
        guard let model else { return }
        let line = checker.line(sourceKey: store?.sourceKey ?? SourceKey.none)
        guard line != model.mailboxLine else { return }
        model.mailboxLine = line
        model.refreshSettings()
    }
}
