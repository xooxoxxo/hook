import SwiftUI
#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif

extension SwiftUI.Color {
    init(platformColor: PlatformColor) {
#if os(macOS)
        self.init(nsColor: platformColor)
#else
        self.init(uiColor: platformColor)
#endif
    }
}

/// Native system surfaces and dynamic color resolution, kept out of the shared tokens.
enum PlatformPalette {
    static var field: PlatformColor {
#if os(macOS)
        .textBackgroundColor
#else
        .secondarySystemGroupedBackground
#endif
    }
    static var window: PlatformColor {
#if os(macOS)
        .windowBackgroundColor
#else
        .systemGroupedBackground
#endif
    }
    static var canvas: PlatformColor {
#if os(macOS)
        .underPageBackgroundColor
#else
        .systemBackground
#endif
    }
    static func adaptive(light: PlatformColor, dark: PlatformColor) -> SwiftUI.Color {
#if os(macOS)
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
#else
        SwiftUI.Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
#endif
    }
    static func accentHue(light: CGFloat, dark: CGFloat) -> SwiftUI.Color {
#if os(macOS)
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let alpha = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor.controlAccentColor.withAlphaComponent(alpha)
        })
#else
        adaptive(light: UIColor.tintColor.withAlphaComponent(light), dark: UIColor.tintColor.withAlphaComponent(dark))
#endif
    }
    static func requiredBadgeRing(groupLight: CGFloat, groupDark: CGFloat, hueLight: CGFloat, hueDark: CGFloat) -> SwiftUI.Color {
#if os(macOS)
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var base = NSColor.white, accent = NSColor.systemBlue
            appearance.performAsCurrentDrawingAppearance {
                base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? base
                accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent
            }
            let lifted = base.blended(withFraction: dark ? groupDark : groupLight, of: .white) ?? base
            return lifted.blended(withFraction: dark ? hueDark : hueLight, of: accent) ?? lifted
        })
#else
        SwiftUI.Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            func blend(_ base: UIColor, _ top: UIColor, _ fraction: CGFloat) -> UIColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
                base.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                top.resolvedColor(with: traits).getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
                return UIColor(red: r + (tr-r)*fraction, green: g + (tg-g)*fraction, blue: b + (tb-b)*fraction, alpha: 1)
            }
            let lifted = blend(.systemGroupedBackground, .white, dark ? groupDark : groupLight)
            return blend(lifted, .tintColor, dark ? hueDark : hueLight)
        })
#endif
    }
}

@MainActor enum PlatformClipboard {
    static func copy(_ text: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#else
        UIPasteboard.general.string = text
#endif
    }
}

extension View {
    @ViewBuilder func askChoicePickerStyle() -> some View {
#if os(macOS)
        pickerStyle(.radioGroup)
#else
        pickerStyle(.inline)
#endif
    }
    @ViewBuilder func askChoiceToggleStyle() -> some View {
#if os(macOS)
        toggleStyle(.checkbox)
#else
        toggleStyle(.automatic)
#endif
    }
    @ViewBuilder func askExitCommand(_ action: @escaping () -> Void) -> some View {
#if os(macOS)
        onExitCommand(perform: action)
#else
        onKeyPress(.escape) { action(); return .handled }
#endif
    }
}
