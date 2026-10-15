import AppKit
import SwiftUI
import RelayCore

/// Relay's shared look. System colours only, so light and
/// dark follow macOS; red is kept for "now".
enum Theme {
    static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .green, .teal, .brown]

    static func monogramColor(_ project: String) -> Color {
        palette[Monogram.colorIndex(project) % palette.count]
    }

    static func urgencyColor(_ urgency: String) -> Color {
        switch urgency {
        case "now": return .red
        case "today": return .orange
        default: return Color(nsColor: .secondaryLabelColor)
        }
    }

    static let cardRadius: CGFloat = 8
    static let codeRadius: CGFloat = 7

    /// Code blocks are dark in both appearances.
    static let codeBackground = Color(white: 0.11)
    static var codeFont: Font { .system(size: 11.5, design: .monospaced) }
}

/// The project's two-letter badge on a stable colour.
struct MonogramView: View {
    private let project: String
    private let size: CGFloat

    init(project: String, size: CGFloat = 22) {
        self.project = project
        self.size = size
    }

    var body: some View {
        Text(verbatim: Sanitize.revealLine(Monogram.letters(project)))
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Theme.monogramColor(project)))
            .accessibilityHidden(true)
    }
}

/// "Now", "Today" or "Whenever" in a fully round pill.
struct UrgencyPill: View {
    private let urgency: String

    init(urgency: String) {
        self.urgency = urgency
    }

    var body: some View {
        let color = Theme.urgencyColor(urgency)
        Text(verbatim: Self.label(urgency))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    static func label(_ urgency: String) -> String {
        switch urgency {
        case "now": return "Now"
        case "today": return "Today"
        case "whenever": return "Whenever"
        default: return Sanitize.revealLine(urgency)
        }
    }
}
