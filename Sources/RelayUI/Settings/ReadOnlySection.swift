import RelayCore
import SwiftUI

/// The first Section of every tab but Queue while config.json is missing or unreadable.
/// It has no ✕: the state lasts until the file is fixed.
public struct ReadOnlySection: View {
    public static let text = "Settings can't be changed until config.json is fixed."
    private let onQueueSettings: () -> Void

    public init(onQueueSettings: @escaping () -> Void) {
        self.onQueueSettings = onQueueSettings
    }

    public var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Label {
                    Text(Self.text).font(DS.Font.prose)
                } icon: {
                    Image(systemName: DS.Symbol.error).foregroundStyle(DS.Color.error)
                }
                Spacer(minLength: DS.Space.inline)
                Button("Queue Settings", action: onQueueSettings)
                    .controlSize(DS.Control.form)
            }
            .accessibilityElement(children: .contain)
        }
    }
}
