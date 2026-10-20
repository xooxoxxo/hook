import RelayCore
import SwiftUI

/// The status bar's popover, opened by clicking the status. Its line never repeats the
/// status bar's own text; every reason goes through UserFacingError.
public struct StatusDetails: View {
    let status: PanelStatus
    let updated: String
    let onTryAgain: () -> Void
    let onSettings: () -> Void
    let onShowConfig: () -> Void

    public init(status: PanelStatus, updated: String, onTryAgain: @escaping () -> Void, onSettings: @escaping () -> Void,
         onShowConfig: @escaping () -> Void) {
        self.status = status
        self.updated = updated
        self.onTryAgain = onTryAgain
        self.onSettings = onSettings
        self.onShowConfig = onShowConfig
    }

    /// Not set up: the status click opens Welcome (or Settings → Queue) instead of a popover.
    public static func opensSetUp(_ status: PanelStatus) -> Bool {
        if case .notSetUp = status.detail { return true }
        return false
    }

    /// The popover's one line of text, or nil when there is nothing to add.
    public static func message(_ status: PanelStatus, updated: String) -> String? {
        switch status.detail {
        case .updated, .none: return updated.isEmpty ? nil : "Updated " + updated
        case .unreachable(let reason): return UserFacingError.text(reason)
        case .config(let note): return UserFacingError.text(note)
        case .listener(let note): return UserFacingError.text(note)
        case .notSetUp: return nil   // never shown: the click opens setup (opensSetUp)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            if let message = Self.message(status, updated: updated) {
                Text(message)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.inline) {
                switch status.detail {
                case .updated, .none:
                    Button("Queue Settings…", action: onSettings)
                case .unreachable:
                    Button("Try Again", action: onTryAgain)
                    Button("Queue Settings…", action: onSettings)
                case .config:
                    Button("Show in Finder", action: onShowConfig)
                    Button("Queue Settings…", action: onSettings)
                case .listener, .notSetUp:
                    EmptyView()
                }
            }
        }
        .font(DS.Font.prose)
        .controlSize(DS.Control.form)
        // StatusBar wraps the popover in DS.Space.popover padding and DS.Metric.helpWidth,
        // so this view only keeps its content leading inside that frame.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
