import SwiftUI

/// Every icon-only button (rule A3): label required, `.help` with its key, 28 pt hit area.
/// Takes no ask text. Disable it with `.disabled(_:)`; the tint drops while disabled.
public struct IconButton: View {
    let symbol: String
    let label: String
    let help: String?
    let tint: Color?
    let scale: Image.Scale
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(_ symbol: String, label: String, help: String? = nil, tint: Color? = nil,
                scale: Image.Scale = .medium, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.help = help
        self.tint = tint
        self.scale = scale
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if let tint, isEnabled {
                    Image(systemName: symbol).imageScale(scale).foregroundStyle(tint)
                } else {
                    Image(systemName: symbol).imageScale(scale)
                }
            }
            // The frame and shape sit inside the label: a borderless button takes clicks
            // only over its label, so this makes the click region the 28 pt square (rule A3).
            .frame(minWidth: DS.Metric.hit, minHeight: DS.Metric.hit)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(Self.helpText(label: label, help: help))
        .accessibilityLabel(label)
    }

    public static func helpText(label: String, help: String?) -> String { help ?? label }
}
