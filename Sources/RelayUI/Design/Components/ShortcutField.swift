import RelayCore
import SwiftUI

/// The shortcut recorder plus its ✕ ("Turn the shortcut off").
public struct ShortcutField: View {
    public static let clearLabel = "Turn the shortcut off"
    let label: String
    let onBegin: @MainActor () -> Void
    let onRecord: @MainActor (HotkeySpec?) -> Void
    let onCancel: @MainActor () -> Void
    let onClear: @MainActor () -> Void

    public init(label: String, onBegin: @escaping @MainActor () -> Void, onRecord: @escaping @MainActor (HotkeySpec?) -> Void,
                onCancel: @escaping @MainActor () -> Void, onClear: @escaping @MainActor () -> Void) {
        self.label = label
        self.onBegin = onBegin
        self.onRecord = onRecord
        self.onCancel = onCancel
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: DS.Space.inline) {
            ShortcutRecorder(label: label, onBegin: onBegin, onRecord: onRecord, onCancel: onCancel).fixedSize()
            IconButton(DS.Symbol.clearShortcut, label: Self.clearLabel) { onClear() }
        }
    }
}
