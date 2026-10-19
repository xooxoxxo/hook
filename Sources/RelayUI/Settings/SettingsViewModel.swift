import RelayCore
import SwiftUI

/// What the Settings tabs and Welcome read and call. `AppModel` conforms in the app;
/// `FixtureSettingsModel` in the gallery.
@MainActor public protocol SettingsViewModel: ObservableObject {
    var settings: SettingsSnapshot { get }
    /// Unsaved Mailbox fields; they live until the Settings window closes.
    var draft: MailboxDraft { get set }
    func save(set: [String: Any], remove: [String])
    func perform(_ action: SettingsAction)
    func sendTestAsk() async -> TestAskResult
    /// Validates and saves the draft, then waits for the first list (10 s cap).
    /// nil on success, else the reason as one sanitized line.
    func connect() async -> String?
}

extension SettingsViewModel {
    /// A control bound to one config.json key: reads the last good config (or `fallback`)
    /// and merge-saves `encode(value)` under `key` on change.
    public func configBinding<Value>(_ key: String, _ read: @escaping (RelayConfig) -> Value, fallback: Value,
                                     encode: @escaping (Value) -> Any) -> Binding<Value> {
        Binding(
            get: { self.settings.config.map(read) ?? fallback },
            set: { self.save(set: [key: encode($0)], remove: []) })
    }
}
