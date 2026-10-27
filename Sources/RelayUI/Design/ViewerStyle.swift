import AppKit

// Design/ViewerStyle.swift. The document viewer's stylesheet, built from Hook's tokens:
// the same system colours and text styles the panel uses, resolved for light and dark.

extension DS {
    public enum Viewer {
        /// The viewer window's first size, in points.
        public static let windowWidth: CGFloat = 720
        public static let windowHeight: CGFloat = 820
        public static let windowMinWidth: CGFloat = 420
        public static let windowMinHeight: CGFloat = 320
        /// The reading column's widest line, and the page inset around it.
        public static let measure: CGFloat = 720
        public static let pageV: CGFloat = 28
        public static let pageH: CGFloat = 32
        public static let lineHeight: CGFloat = 1.55
        /// Body text: the stock body style one point up, for reading.
        public static var textSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize + 1 }
        public static var codeSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize }
        /// The quote bar and the rule under a large heading.
        public static let quoteBar: CGFloat = 3
        public static let hairline: CGFloat = 1
        /// The share of the separator colour a table row stripe gets.
        public static let stripe: Double = 0.35

        /// The colours, as CSS, for one appearance.
        struct Palette {
            var text, secondary, background, link, codeFill, separator, quoteBar, blocked: String
        }

        static func palette(_ name: NSAppearance.Name) -> Palette {
            var palette = Palette(text: "", secondary: "", background: "", link: "", codeFill: "", separator: "",
                                  quoteBar: "", blocked: "")
            let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
            appearance.performAsCurrentDrawingAppearance {
                palette = Palette(
                    text: css(.labelColor),
                    secondary: css(.secondaryLabelColor),
                    background: css(.textBackgroundColor),
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

        static func css(_ color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "CanvasText" }
            func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            let alpha = (min(max(rgb.alphaComponent, 0), 1) * 1000).rounded() / 1000
            return "rgba(\(byte(rgb.redComponent)), \(byte(rgb.greenComponent)), \(byte(rgb.blueComponent)), \(alpha))"
        }

        static func variables(_ palette: Palette) -> String {
            """
            --text: \(palette.text); --secondary: \(palette.secondary); --background: \(palette.background);
            --link: \(palette.link); --code-fill: \(palette.codeFill); --separator: \(palette.separator);
            --quote-bar: \(palette.quoteBar); --blocked: \(palette.blocked);
            """
        }

        /// The whole stylesheet: light by default, dark under `prefers-color-scheme: dark`
        /// (WebKit follows the window's appearance).
        public static func stylesheet() -> String {
            let light = variables(palette(.aqua)), dark = variables(palette(.darkAqua))
            let radius = Metric.codeRadius
            return """
            :root { color-scheme: light dark; \(light) }
            @media (prefers-color-scheme: dark) { :root { \(dark) } }
            html { background: var(--background); color: var(--text);
              font: \(textSize)px/\(lineHeight) -apple-system, system-ui, sans-serif;
              -webkit-text-size-adjust: none; }
            body { margin: 0; padding: \(pageV)px \(pageH)px; }
            main { max-width: \(measure)px; margin: 0 auto; overflow-wrap: anywhere; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 600; }
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
            table { border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: \(hairline)px solid var(--separator); padding: 0.3em 0.7em; text-align: left; }
            th { font-weight: 600; }
            tr:nth-child(2n) td { background: color-mix(in srgb, var(--separator) \(Int(stripe * 100))%, transparent); }
            img { max-width: 100%; }
            li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.3em; }
            input[type=checkbox] { margin: 0 0.4em 0 0; }
            .hook-blocked { color: var(--blocked); font-size: 0.9em; }
            pre.plain { background: none; padding: 0; white-space: pre-wrap; overflow-wrap: anywhere;
              font-size: \(codeSize)px; }
            """
        }
    }
}
