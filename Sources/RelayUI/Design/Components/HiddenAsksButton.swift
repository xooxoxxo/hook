import RelayCore
import SwiftUI

/// Design/HiddenAsksButton: how many open asks the filter hides, with the `now`
/// symbol when some of them are "now". It stays whole; the FilterToken gives way instead.
public struct HiddenAsksButton: View {
    let hidden: HiddenCount
    let onClear: () -> Void

    public init(hidden: HiddenCount, onClear: @escaping () -> Void) {
        self.hidden = hidden
        self.onClear = onClear
    }

    public var body: some View {
        Button(action: onClear) {
            Group {
                if hidden.now > 0 {
                    Text(Image(systemName: DS.Symbol.now)).foregroundStyle(DS.Color.now) + Text(" " + Self.text(hidden))
                } else {
                    Text(Self.text(hidden))
                }
            }
            .font(DS.Font.meta)
            .monospacedDigit()
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.secondary)
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(Self.accessibilityText(hidden))
        .help("Show all projects (⌃⌘A)")
    }

    public static func text(_ hidden: HiddenCount) -> String {
        "\(hidden.total) more in other projects" + (hidden.now > 0 ? ", \(hidden.now) now" : "")
    }

    public static func accessibilityText(_ hidden: HiddenCount) -> String {
        "\(hidden.total) more \(hidden.total == 1 ? "ask" : "asks") in other projects"
            + (hidden.now > 0 ? ", \(hidden.now) now" : "") + ". Show all projects"
    }
}
