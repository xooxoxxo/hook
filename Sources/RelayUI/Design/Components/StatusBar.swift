import RelayCore
import SwiftUI

/// Design/StatusBar (design §4.3): the queue's state on the left, which opens a details
/// popover, and Settings on the right. The one place a persistent problem shows in the panel (rule A7).
public struct StatusBar<Details: View>: View {
    let symbol: StatusSymbol
    let text: String
    let onSettings: () -> Void
    /// Set for the one state whose click opens setup instead of the popover (§4.3 "not set up").
    let onActivate: (() -> Void)?
    let details: () -> Details
    @State private var showDetails = false

    public init(symbol: StatusSymbol, text: String, onSettings: @escaping () -> Void, onActivate: (() -> Void)? = nil,
                @ViewBuilder details: @escaping () -> Details) {
        self.symbol = symbol
        self.text = text
        self.onSettings = onSettings
        self.onActivate = onActivate
        self.details = details
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: DS.Space.inline) {
                Button {
                    if let onActivate { onActivate() } else { showDetails = true }
                } label: {
                    Label {
                        Text(text).foregroundStyle(DS.Color.secondary)
                    } icon: {
                        iconView
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(StatusBarText.accessibilityText(text))
                .popover(isPresented: $showDetails, arrowEdge: .top) {
                    details()
                        .padding(DS.Space.popover)
                        .frame(width: DS.Metric.helpWidth)
                }
                Spacer()
                IconButton(DS.Symbol.settings, label: "Settings", help: "Settings (⌘,)", action: onSettings)
            }
            .font(DS.Font.meta)
            .padding(.horizontal, DS.Space.gutter)
            .frame(height: DS.Metric.statusBar)
            .background(DS.Color.bar)
        }
    }

    @ViewBuilder private var iconView: some View {
        switch symbol {
        case .ok: Image(systemName: DS.Symbol.statusOK).imageScale(.small).foregroundStyle(DS.Color.done)
        case .down: Image(systemName: DS.Symbol.statusDown).imageScale(.small).foregroundStyle(DS.Color.warn)
        case .connecting: ProgressView().controlSize(.mini).accessibilityLabel("Connecting")
        case .notSetUp: Image(systemName: DS.Symbol.notSetUp).foregroundStyle(DS.Color.secondary)
        case .away: Image(systemName: DS.Symbol.away).imageScale(.small).foregroundStyle(DS.Color.secondary)
        }
    }
}

/// StatusBar's strings. A non-generic namespace, since `StatusBar` is generic.
public enum StatusBarText {
    public static func accessibilityText(_ text: String) -> String { "Status: \(text). Shows details" }
}
