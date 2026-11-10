import AppKit
import RelayCore
import SwiftUI

/// Settings › Documents: a few lines set the way the viewer would set them with `theme`
/// (a heading, a sentence with a link, inline code), at the theme's text size.
/// Plain SwiftUI text on the theme's background; the colours come from `DS.Viewer`.
public struct ViewerThemePreview: View {
    let theme: ViewerTheme
    @Environment(\.colorScheme) private var scheme

    public init(theme: ViewerTheme) {
        self.theme = theme
    }

    /// The appearance the page would resolve System colours in: the theme's own, else the window's.
    private var appearance: NSAppearance.Name {
        DS.Viewer.appearance(theme) ?? (scheme == .dark ? .darkAqua : .aqua)
    }

    private func color(_ role: ViewerTheme.Role) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: DS.Viewer.nsColor(DS.Viewer.color(role, in: theme, appearance: appearance)) ?? .labelColor)
    }

    private var size: CGFloat { DS.Viewer.textSize + CGFloat(theme.textSize) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            Text(ViewerThemePreview.heading)
                .font(.system(size: size * DS.Viewer.previewHeadingScale, weight: .semibold))
                .foregroundStyle(color(.headings))
            (Text(ViewerThemePreview.body) + Text(ViewerThemePreview.link).foregroundColor(color(.links))
                + Text(ViewerThemePreview.bodyEnd))
                .font(.system(size: size))
                .foregroundStyle(color(.text))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.inline) {
                Text(ViewerThemePreview.codeLead)
                    .font(.system(size: size))
                    .foregroundStyle(color(.text))
                Text(ViewerThemePreview.code)
                    .font(.system(size: DS.Viewer.codeSize, design: .monospaced))
                    .foregroundStyle(color(.text))
                    .padding(.horizontal, DS.Space.rowLine)
                    .background(color(.code), in: RoundedRectangle(cornerRadius: DS.Metric.codeRadius / 2))
            }
        }
        .padding(DS.Space.step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(.background), in: RoundedRectangle(cornerRadius: DS.Metric.codeRadius))
        .overlay(RoundedRectangle(cornerRadius: DS.Metric.codeRadius)
            .strokeBorder(SwiftUI.Color(nsColor: .separatorColor), lineWidth: DS.Viewer.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the viewer's look")
    }

    static let heading = "Release plan"
    static let body = "The beta goes to everyone on Friday. Read the "
    static let link = "rollback notes"
    static let bodyEnd = " first."
    static let codeLead = "Keep"
    static let code = "beta = on"
}
