import RelayUI
import AppKit
import RelayCore

// Design/ViewerStyle.swift. The document viewer's stylesheet, built from Hook's tokens:
// the same system colours and text styles the panel uses, resolved for light and dark,
// or a fixed preset palette, with the owner's own colours (`ViewerTheme`) over either.

extension DS {
    public enum Viewer {
        /// The viewer window's first size, in points.
        public static let windowWidth: CGFloat = 720
        public static let windowHeight: CGFloat = 820
        public static let windowMinWidth: CGFloat = 420
        public static let windowMinHeight: CGFloat = 320
        /// The reading column's widest line for each `ViewerTheme.Width` (nil: the window's
        /// width), and the page inset around it.
        public static func measure(_ width: ViewerTheme.Width) -> CGFloat? {
            switch width {
            case .full: nil
            case .wide: 960
            case .narrow: 720
            }
        }
        public static let pageV: CGFloat = 28
        public static let pageH: CGFloat = 32
        public static let lineHeight: CGFloat = 1.55
        /// Body text: the stock body style one point up, for reading.
        public static var textSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize + 1 }
        public static var codeSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize }
        /// The front matter strip: the stock caption style one point up, like the body.
        public static var captionSize: CGFloat { NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1 }
        /// The quote bar and the rule under a large heading.
        public static let quoteBar: CGFloat = 3
        public static let hairline: CGFloat = 1
        /// The share of the separator colour a table row stripe gets.
        public static let stripe: Double = 0.35
        /// The share of the text colour secondary text gets over the background, for a palette
        /// that isn't the system's.
        public static let secondaryMix: Double = 0.7
        /// A table cell's narrowest width, in em: a short column doesn't shrink to a sliver.
        public static let cellMinWidth: Double = 4
        /// The preview's heading, as a share of the body size (an h2's).
        public static let previewHeadingScale: CGFloat = 1.35
        /// How long Settings waits after the last colour change before it saves.
        public static let saveDelay: Duration = .milliseconds(250)

        /// The colours, as CSS, for one appearance.
        struct Palette: Equatable {
            var text, secondary, background, heading, link, codeFill, separator, quoteBar, blocked: String
        }

        static func palette(_ name: NSAppearance.Name) -> Palette {
            var palette = Palette(text: "", secondary: "", background: "", heading: "", link: "", codeFill: "",
                                  separator: "", quoteBar: "", blocked: "")
            let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
            appearance.performAsCurrentDrawingAppearance {
                palette = Palette(
                    text: css(.labelColor),
                    secondary: css(.secondaryLabelColor),
                    background: css(.textBackgroundColor),
                    heading: css(.labelColor),
                    link: css(.linkColor),
                    // DS.Color.codeFill: quaternary at 0.6.
                    codeFill: css(NSColor.quaternaryLabelColor.withAlphaComponent(
                        NSColor.quaternaryLabelColor.alphaComponent * 0.6)),
                    separator: css(.separatorColor),
                    quoteBar: css(.tertiaryLabelColor),
                    blocked: css(.systemOrange))
            }
            return palette
        }

        /// The fixed palettes, by role, `#rrggbb`. System has none: it follows the appearance.
        public static func presetColors(_ preset: ViewerTheme.Preset) -> [ViewerTheme.Role: String]? {
            switch preset {
            case .system: nil
            case .paper: [.background: "#ffffff", .text: "#1f1f1f", .headings: "#0d0d0d", .links: "#0b57d0",
                          .code: "#f1f1f1", .rules: "#d4d4d4"]
            case .sepia: [.background: "#f4ecd8", .text: "#433422", .headings: "#2b2014", .links: "#8a4b14",
                          .code: "#e8dcc0", .rules: "#cfbe9a"]
            case .night: [.background: "#16171a", .text: "#d4d4d8", .headings: "#f2f2f4", .links: "#7fb4ff",
                          .code: "#25272c", .rules: "#3b3d44"]
            }
        }

        /// The colour `role` shows with `theme`, `#rrggbb`: the owner's, else the preset's,
        /// else the system colour in `appearance`.
        public static func color(_ role: ViewerTheme.Role, in theme: ViewerTheme,
                                 appearance: NSAppearance.Name = .aqua) -> String {
            if let own = theme.colors[role] { return own }
            if let fixed = presetColors(theme.preset)?[role] { return fixed }
            var out = ""
            (NSAppearance(named: appearance) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                let page = NSColor.textBackgroundColor
                let system: NSColor = switch role {
                case .background: page
                case .text, .headings: .labelColor
                case .links: .linkColor
                case .code: NSColor.quaternaryLabelColor.withAlphaComponent(
                    NSColor.quaternaryLabelColor.alphaComponent * 0.6)
                case .rules: .separatorColor
                }
                out = hex(system, over: page)
            }
            return out
        }

        /// The window appearance a theme wants: nil (follow Hook's) for System with the
        /// system background; else light or dark by how dark the background is.
        public static func appearance(_ theme: ViewerTheme) -> NSAppearance.Name? {
            guard theme.colors[.background] != nil || theme.preset != .system else { return nil }
            return ViewerTheme.isDark(color(.background, in: theme)) ? .darkAqua : .aqua
        }

        static func css(_ color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "CanvasText" }
            func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            let alpha = (min(max(rgb.alphaComponent, 0), 1) * 1000).rounded() / 1000
            return "rgba(\(byte(rgb.redComponent)), \(byte(rgb.greenComponent)), \(byte(rgb.blueComponent)), \(alpha))"
        }

        /// `color` as opaque `#rrggbb`, a translucent colour laid over `background` first.
        public static func hex(_ color: NSColor, over background: NSColor = .white) -> String {
            guard var rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
            if rgb.alphaComponent < 1, let base = background.usingColorSpace(.sRGB),
               let laid = base.blended(withFraction: rgb.alphaComponent, of: rgb.withAlphaComponent(1)) {
                rgb = laid
            }
            func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent),
                          byte(rgb.blueComponent))
        }

        /// `#rrggbb` as an sRGB colour; nil for anything else.
        public static func nsColor(_ hex: String) -> NSColor? {
            guard let rgb = ViewerTheme.components(hex) else { return nil }
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }

        static func variables(_ palette: Palette) -> String {
            """
            --text: \(palette.text); --secondary: \(palette.secondary); --background: \(palette.background);
            --heading: \(palette.heading); --link: \(palette.link); --code-fill: \(palette.codeFill);
            --separator: \(palette.separator); --quote-bar: \(palette.quoteBar); --blocked: \(palette.blocked);
            """
        }

        /// The variables a theme's own colours (and a fixed preset) set over the system palette.
        static func overrides(_ theme: ViewerTheme) -> String {
            var colors = presetColors(theme.preset) ?? [:]
            colors.merge(theme.colors) { _, own in own }
            var out: [String] = []
            if let value = colors[.background] { out.append("--background: \(value);") }
            if let value = colors[.text] { out.append("--text: \(value);") }
            // Headings follow the text unless they have a colour of their own.
            if let value = colors[.headings] ?? colors[.text] { out.append("--heading: \(value);") }
            if let value = colors[.links] { out.append("--link: \(value);") }
            if let value = colors[.code] { out.append("--code-fill: \(value);") }
            if let value = colors[.rules] { out.append("--separator: \(value); --quote-bar: \(value);") }
            if colors[.text] != nil || colors[.background] != nil {
                let share = Int(secondaryMix * 100)
                out.append("--secondary: color-mix(in srgb, var(--text) \(share)%, var(--background));")
            }
            return out.joined(separator: " ")
        }

        /// The whole stylesheet for `theme`: the system palette light by default and dark under
        /// `prefers-color-scheme: dark` (WebKit follows the window's appearance), then the
        /// preset's and the owner's colours over both. The column is as wide as the window
        /// allows, up to the theme's measure; text breaks between words, a word longer than
        /// the line breaks only where it must, and a table wider than the column scrolls
        /// inside itself.
        public static func stylesheet(theme: ViewerTheme = ViewerTheme()) -> String {
            let light = variables(palette(.aqua)), dark = variables(palette(.darkAqua))
            let radius = Metric.codeRadius
            let scheme = appearance(theme).map { $0 == .darkAqua ? "dark" : "light" } ?? "light dark"
            let column = measure(theme.width).map { "\(Int($0))px" } ?? "none"
            let size = textSize + CGFloat(theme.textSize)
            let own = overrides(theme)
            return """
            :root { color-scheme: \(scheme); \(light) }
            @media (prefers-color-scheme: dark) { :root { \(dark) } }
            \(own.isEmpty ? "" : ":root { \(own) }")
            html { background: var(--background); color: var(--text);
              font: \(size)px/\(lineHeight) -apple-system, system-ui, sans-serif;
              -webkit-text-size-adjust: none; }
            body { margin: 0; padding: \(pageV)px \(pageH)px; }
            main { max-width: \(column); margin: 0 auto; overflow-wrap: break-word; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 600; color: var(--heading); }
            h1 { font-size: 1.75em; padding-bottom: 0.25em; border-bottom: \(hairline)px solid var(--separator); }
            h2 { font-size: 1.35em; padding-bottom: 0.2em; border-bottom: \(hairline)px solid var(--separator); }
            h3 { font-size: 1.15em; } h4, h5, h6 { font-size: 1em; }
            main > :first-child { margin-top: 0; }
            p, ul, ol, blockquote, pre, table { margin: 0 0 0.9em; }
            ul, ol { padding-left: 1.6em; } li + li { margin-top: 0.2em; }
            a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
            code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: \(codeSize)px; }
            code { background: var(--code-fill); border-radius: \(radius / 2)px; padding: 0.1em 0.3em; }
            pre { background: var(--code-fill); border-radius: \(radius)px; padding: 0.7em 0.9em; overflow-x: auto; }
            pre code { background: none; padding: 0; border-radius: 0; }
            blockquote { margin-left: 0; padding: 0 0 0 0.9em; color: var(--secondary);
              border-left: \(quoteBar)px solid var(--quote-bar); }
            hr { border: 0; border-top: \(hairline)px solid var(--separator); margin: 1.4em 0; }
            table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%;
              width: max-content; }
            th, td { border: \(hairline)px solid var(--separator); padding: 0.3em 0.7em; text-align: left;
              vertical-align: top; min-width: \(cellMinWidth)em; overflow-wrap: normal; word-break: normal; }
            th { font-weight: 600; }
            tr:nth-child(2n) td { background: color-mix(in srgb, var(--separator) \(Int(stripe * 100))%, transparent); }
            img { max-width: 100%; }
            li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.3em; }
            input[type=checkbox] { margin: 0 0.4em 0 0; }
            .hook-blocked { color: var(--blocked); font-size: 0.9em; }
            pre.plain { background: none; padding: 0; white-space: pre-wrap; overflow-wrap: anywhere;
              font-size: \(codeSize)px; }
            .front { max-width: \(column); margin: 0 auto 1.2em; font-size: \(captionSize)px;
              line-height: 1.6; color: var(--secondary); }
            .front summary { list-style: none; cursor: default; }
            .front summary::-webkit-details-marker { display: none; }
            .front-line { display: flex; align-items: baseline; gap: 0.6em; white-space: nowrap; }
            .front-items { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
            .front-chip { background: var(--code-fill); border-radius: \(radius)px; padding: 0.05em 0.5em; }
            .front-chip + .front-item { margin-left: 0.4em; }
            .front-item + .front-item::before { content: "· "; }
            .front-key { opacity: 0.75; }
            .front-more { flex: none; }
            .front-more::before { content: "\\25B8\\00A0"; }
            .front[open] .front-more::before { content: "\\25BE\\00A0"; }
            .front dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.15em 1em; margin: 0.4em 0 0; }
            .front dt { opacity: 0.75; }
            .front dd { margin: 0; overflow-wrap: anywhere; white-space: pre-wrap; }
            .front-raw summary { list-style: revert; }
            .front-raw summary::-webkit-details-marker { display: revert; }
            .front-raw pre { font-size: \(captionSize)px; margin: 0.4em 0 0; white-space: pre-wrap; }
            """
        }
    }
}
