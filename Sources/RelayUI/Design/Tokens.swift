import AppKit
import RelayCore
import SwiftUI

// Design/Tokens.swift. Every size, colour, font, symbol and duration the views use lives here; scripts/check-tokens.sh fails a literal anywhere else.

public enum DS {
    public enum Space {
        public static let rowLine: CGFloat = 4
        public static let rowInsetV: CGFloat = 6
        /// Leading/trailing List row inset. The stock `.sidebar` List already places row content
        /// 16 pt (= gutter) from the panel edge at inset 0 (measured, macOS 15), so 0 lands row text on the gutter.
        public static let rowInsetH: CGFloat = 0
        /// Stock sidebar section headers start 14 pt from the panel edge (measured); this nudge puts them on the gutter.
        public static let sectionHeaderLead: CGFloat = 2
        /// A queue section header's top and bottom padding inside its row, the same collapsed or
        /// expanded, so a header never changes height when its group folds.
        public static let sectionHeaderV: CGFloat = 4
        /// Between a collapsed header's name and its peek line (the group's newest ask).
        public static let headerPeek: CGFloat = 1
        /// The count pill's padding round its digits.
        public static let countPillH: CGFloat = 6
        public static let countPillV: CGFloat = 1
        public static let stepPart: CGFloat = 6
        public static let inline: CGFloat = 8
        public static let marker: CGFloat = 10
        public static let step: CGFloat = 16
        public static let subIndent: CGFloat = 38
        public static let subStep: CGFloat = 10
        public static let section: CGFloat = 24
        public static let gutter: CGFloat = 16
        public static let bodyV: CGFloat = 16
        public static let codeH: CGFloat = 10
        public static let codeV: CGFloat = 8
        public static let currentStep: CGFloat = 4
        /// The action bar's top and bottom inset when its caption sits on a line above the buttons.
        public static let barStackV: CGFloat = 10
        /// Between a docked bar's title and its caption (the crash bar).
        public static let barCaption: CGFloat = 1
        /// A sheet's or dialog window's edge inset, and the gap between its sections (the crash report window).
        public static let sheet: CGFloat = 20
        public static let sheetSection: CGFloat = 14
        /// GroupBox content inset (5 pt, measured) + currentStep: the current step's box bleeds out by this
        /// so its marker and text stay on the todo/done column.
        public static let currentBleed: CGFloat = 9
        /// How far a required item's hue reaches past a sub-step row or a section, so the text
        /// inside it keeps its place (owner pick 1).
        public static let requiredBleed: CGFloat = inline
        /// The Welcome window's form pages end this far above the footer, so the last row of a
        /// long page never sits on the dots.
        public static let setupFormEnd: CGFloat = 16
        public static let emptyLine: CGFloat = 24
        public static let popover: CGFloat = 16
        /// A queue card's content inset.
        public static let cardPadding: CGFloat = 12
        /// The gap between two queue cards.
        public static let cardGap: CGFloat = 8
        /// A queue card's edge, from the panel edge.
        public static let cardEdge: CGFloat = 10
        /// Between the monogram and the project name in a card's top row.
        public static let cardMeta: CGFloat = 6
        /// The card row's List inset: leading/trailing puts the card text `cardPadding` inside
        /// the card edge (the stock row content already sits on the gutter at inset 0);
        /// top/bottom is half the gap plus the padding.
        public static let cardInsetH: CGFloat = cardEdge + cardPadding - gutter
        public static let cardInsetV: CGFloat = cardGap / 2 + cardPadding
        /// Where card text starts, and (mirrored) where its trailing text ends.
        public static let cardText: CGFloat = cardEdge + cardPadding
        /// A grouped step row's inner padding (the inset grouped list in the detail).
        public static let groupRowH: CGFloat = 12
        public static let groupRowV: CGFloat = 9
        /// A sub-step row's top and bottom padding inside its parent's row.
        public static let subRowV: CGFloat = 5
        /// Where a grouped row's text starts, from the group's edge: the padding, then the
        /// marker column (hit) and its gap. Hairlines between rows start here.
        public static let groupText: CGFloat = groupRowH + Metric.hit + marker
        /// An option row's inner padding.
        public static let optionH: CGFloat = 12
        public static let optionV: CGFloat = 8
        /// Where an option's text starts: the padding, the number column and its gap.
        public static let optionText: CGFloat = optionH + Metric.optionNumber + inline
        /// The setup window's page inset, around the hero and the footer.
        public static let setupPad: CGFloat = 32
        /// Between the dots and the footer buttons.
        public static let setupFooter: CGFloat = 14
        /// Between a file row's name and its folder line.
        public static let fileLine: CGFloat = 1
        /// Settings › Agents: the footer under both columns, its sides and its top and bottom.
        public static let paneFooterH: CGFloat = 20
        public static let paneFooterV: CGFloat = 12
        /// Between a sidebar harness's name and its state caption, and the row's extra top and bottom.
        public static let harnessCaption: CGFloat = 1
        public static let harnessRowV: CGFloat = 2
        /// Between a state symbol and its label (Installed, Edited by you).
        public static let stateLabel: CGFloat = 4
    }

    public enum Metric {
        public static let panelWidth: CGFloat = 380
        /// The crash report preview's scroll box.
        public static let reportPreview: CGFloat = 220
        /// The crash report window's content width (it's its own window, not panel-wide).
        public static let crashReportWidth: CGFloat = 520
        public static let header: CGFloat = 44
        public static let filterRow: CGFloat = 32
        public static let filterTokenMax: CGFloat = 160
        public static let statusBar: CGFloat = 36
        public static let undoBar: CGFloat = 36
        public static let actionBar: CGFloat = 56
        public static let hit: CGFloat = 28
        public static let rowProgress: CGFloat = 44
        public static let codeRadius: CGFloat = 6
        public static let helpWidth: CGFloat = 300
        public static let settingsWidth: CGFloat = 600
        public static let settingsInset: CGFloat = 120
        public static let fieldWide: CGFloat = 320
        /// The mailbox fields in the setup window, where a row is narrower than in Settings.
        public static let fieldSetup: CGFloat = 270
        public static let welcomeWidth: CGFloat = 480
        /// The setup window's fixed height, so pages push without the window resizing.
        public static let welcomeHeight: CGFloat = 500
        /// The About window's width.
        public static let aboutWidth: CGFloat = 340
        /// The app icon on the Welcome, Setup and About pages.
        public static let appIcon: CGFloat = 72
        public static let appIconRadius: CGFloat = 16
        /// A progress dot in the setup footer.
        public static let setupDot: CGFloat = 7
        /// A setup row's leading symbol column.
        public static let setupSymbol: CGFloat = 20
        /// The status item's length: the 16 pt glyph and 4 pt either side, the same for both glyphs.
        public static let menuBarItem: CGFloat = 24
        public static let badge: CGFloat = 13
        public static let badgeDot: CGFloat = 7
        public static let dragThreshold: CGFloat = 3
        public static let recorderMin: CGFloat = 130
        /// The List's `defaultMinListRowHeight`, = hit.
        public static let rowMinHeight: CGFloat = 28
        public static let cardRadius: CGFloat = 8
        public static let cardBorder: CGFloat = 0.5
        /// The card hairline under Increase Contrast.
        public static let cardBorderContrast: CGFloat = 1
        public static let cardSelectedBorder: CGFloat = 2
        public static let monogram: CGFloat = 18
        public static let monogramRadius: CGFloat = 5
        /// The inset grouped steps list's corner.
        public static let groupRadius: CGFloat = 10
        /// A long text's field (a message, a report): from 3 lines, growing to 8, then scrolling.
        public static let fieldLines: ClosedRange<Int> = 3...8
        /// A choice's own words field (owner pick 5 A): two lines to start, then up to 8.
        public static let choiceFieldLines: ClosedRange<Int> = 2...8
        public static let messageFieldRadius: CGFloat = 6
        public static let messageFieldInset: CGFloat = 4
        public static let messageFieldStroke: CGFloat = 0.5
        /// The required hue's inset from the row's edges.
        public static let targetInset: CGFloat = 3
        /// An option list's corner.
        public static let optionRadius: CGFloat = 8
        /// An option row's minimum height: roomier than a stock radio row.
        public static let optionRow: CGFloat = 36
        /// The number column of a reply choice row (keys 1–6).
        public static let optionNumber: CGFloat = 14
        /// A file row's document icon.
        public static let fileIcon: CGFloat = 28
        /// A harness's mark in Settings › Agents and the setup window, a little larger than a monogram.
        public static let harnessMark: CGFloat = 24
        public static let harnessMarkRadius: CGFloat = 6
        /// Settings › Agents: the harness list's width, and the tab's one height whichever harness
        /// is selected (the list and the detail scroll inside it).
        public static let agentsSidebar: CGFloat = 200
        public static let agentsHeight: CGFloat = 540
        /// Show Difference's sheet, and its diff's scroll box.
        public static let diffSheetWidth: CGFloat = 560
        public static let diffSheetBody: CGFloat = 320
        /// The action bar's Skip, Done, Send & Done and Discard & Done: wide enough to hit at a
        /// glance (owner pick 1); two of them beside each other fit the panel.
        public static let barButtonMinWidth: CGFloat = 84
        /// The dot on a required step's marker, and beside a required section's "?".
        public static let requiredBadge: CGFloat = 7
        /// The ring round that dot, in the row's surface colour (`DS.Color.requiredBadgeRing`), so
        /// the dot stays apart from an accent marker it meets (at larger text sizes they touch).
        public static let requiredBadgeRing: CGFloat = 1.5
        /// The fade at the bottom of a Welcome form page that scrolls under the footer.
        public static let setupFade: CGFloat = 24
    }

    public enum Font {
        /// Gallery-only text multiplier for --xl. macOS ignores .dynamicTypeSize for text styles, so RelayGallery sets this once before rendering. Hook never sets it, and at 1 every token is exactly its stock text style.
        nonisolated(unsafe) public static var galleryScale: CGFloat = 1

        /// The stock text style `s`, or under `galleryScale` the same style's NSFont scaled, which keeps its weight (headline's bold).
        static func style(_ s: SwiftUI.Font.TextStyle, _ ns: NSFont.TextStyle) -> SwiftUI.Font {
            if galleryScale == 1 { return SwiftUI.Font.system(s) }
            let base = NSFont.preferredFont(forTextStyle: ns)
            return SwiftUI.Font(base.withSize(base.pointSize * galleryScale) as CTFont)
        }

        public static var listTitle: SwiftUI.Font { style(.headline, .headline) }
        public static var askTitle: SwiftUI.Font { style(.title3, .title3).weight(.semibold) }
        public static var heading: SwiftUI.Font { style(.headline, .headline) }
        /// The heading font's cap height, for a mark centred on a heading's capitals.
        public static var headingCapHeight: CGFloat {
            NSFont.preferredFont(forTextStyle: .headline).capHeight * galleryScale
        }
        /// The cap height of a label in `style`, for a "?" centred on that label's capitals.
        public static func capHeight(_ style: HelpLabelStyle) -> CGFloat {
            let ns: NSFont.TextStyle
            switch style {
            case .body: ns = .body
            case .heading: ns = .headline
            case .prose: ns = .callout
            case .caption: ns = .caption1
            case .subheadline: ns = .subheadline
            }
            return NSFont.preferredFont(forTextStyle: ns).capHeight * galleryScale
        }
        public static var body: SwiftUI.Font { style(.body, .body) }
        public static var currentAction: SwiftUI.Font { style(.headline, .headline) }
        public static var meta: SwiftUI.Font { style(.subheadline, .subheadline) }
        public static var prose: SwiftUI.Font { style(.callout, .callout) }
        public static var code: SwiftUI.Font { style(.callout, .callout).monospaced() }
        /// A crash report preview: a whole report fits the window's scroll box.
        public static var report: SwiftUI.Font { style(.caption, .caption1).monospaced() }
        public static var caption: SwiftUI.Font { style(.caption, .caption1) }
        /// A section header's count pill: semibold digits that keep their width.
        public static var countPill: SwiftUI.Font { style(.caption, .caption1).weight(.semibold).monospacedDigit() }
        public static var welcomeTitle: SwiftUI.Font { style(.title2, .title2).weight(.semibold) }
        public static var badgeDigit: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .bold) }
        /// A queue card's title.
        public static var cardTitle: SwiftUI.Font { style(.headline, .headline) }
        /// The monogram's two letters, sized to `Metric.monogram`.
        public static var monogram: SwiftUI.Font { .system(size: 8, weight: .bold) }
        /// The symbol on the app icon placeholder, sized to `Metric.appIcon`.
        public static var appSymbol: SwiftUI.Font { .system(size: 34, weight: .semibold) }
        /// A sheet's or dialog window's leading symbol (the crash report window's warning).
        public static var sheetSymbol: SwiftUI.Font { .system(size: 28) }
        /// The Done page's hero symbol.
        public static var heroSymbol: SwiftUI.Font { .system(size: 52, weight: .regular) }
        /// A harness mark's two letters, sized to `Metric.harnessMark`.
        public static var harnessMark: SwiftUI.Font { .system(size: 10, weight: .bold) }
        /// The owner key's 6-digit enrollment code in Settings › Queue.
        public static var enrollCode: SwiftUI.Font { .system(size: 34, weight: .semibold, design: .monospaced) }
    }

    public enum Color {
        public static let primary = SwiftUI.Color.primary
        public static let secondary = SwiftUI.Color.secondary
        public static let tertiary = HierarchicalShapeStyle.tertiary
        public static let accent = SwiftUI.Color.accentColor
        public static let now = SwiftUI.Color.red
        public static let today = SwiftUI.Color.orange
        public static let whenever = SwiftUI.Color.secondary
        public static let done = SwiftUI.Color.green
        public static let warn = SwiftUI.Color.orange
        public static let error = SwiftUI.Color.red
        /// Small (11 pt) text in the warn, done and error tints: Look-closer flags and the
        /// Changed, New and Removed tags. The system colours reach only about 2.2:1 on the light
        /// steps list, so light mode takes darker tints and dark mode lighter ones; each reaches
        /// 4.5:1 on the list and on its own tag's tint (`TokensTests`).
        public static let warnText = adaptive(light: TextTint.warnLight, dark: TextTint.warnDark)
        public static let doneText = adaptive(light: TextTint.doneLight, dark: TextTint.doneDark)
        public static let errorText = adaptive(light: TextTint.errorLight, dark: TextTint.errorDark)
        /// A tag's capsule: its text colour at this opacity.
        public static let tagFillOpacity: Double = 0.14
        /// A redaction placeholder in the report preview (<host>, <redacted>, ~).
        public static let redactedText = SwiftUI.Color.accentColor
        public static let redactedFill = SwiftUI.Color.accentColor.opacity(0.14)
        /// A multi-line field drawn like the stock rounded text field.
        public static let fieldFill = SwiftUI.Color(nsColor: .textBackgroundColor)
        public static let fieldStroke = SwiftUI.Color.primary.opacity(0.18)
        /// A required item's badge (owner pick 1, RD 25): Done's own accent, so the mark reads as
        /// "this feeds Done".
        public static let required = SwiftUI.Color.accentColor
        /// A required item's row hue: the accent at a low opacity, stronger over the dark list
        /// (`RequiredHue`); `requiredRowContrast` under Increase Contrast.
        public static let requiredRow = accentHue(light: RequiredHue.light, dark: RequiredHue.dark)
        public static let requiredRowContrast = accentHue(light: RequiredHue.lightContrast, dark: RequiredHue.darkContrast)
        /// The system accent at `light` or `dark` opacity, by appearance.
        static func accentHue(light: CGFloat, dark: CGFloat) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let alpha = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor.controlAccentColor.withAlphaComponent(alpha)
            })
        }
        public enum RequiredHue {
            public static let light: CGFloat = 0.08
            public static let dark: CGFloat = 0.16
            public static let lightContrast: CGFloat = 0.16
            public static let darkContrast: CGFloat = 0.26
        }
        enum TextTint {
            static let warnLight = NSColor(srgbRed: 0.60, green: 0.29, blue: 0.0, alpha: 1)
            static let warnDark = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
            static let doneLight = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.19, alpha: 1)
            static let doneDark = NSColor(srgbRed: 0.40, green: 0.88, blue: 0.50, alpha: 1)
            static let errorLight = NSColor(srgbRed: 0.70, green: 0.15, blue: 0.12, alpha: 1)
            static let errorDark = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.67, alpha: 1)
        }
        public static let codeFill = AnyShapeStyle(.quaternary.opacity(0.6))
        public static let bar = Material.bar
        public static var badge: NSColor { .systemRed }
        public static var badgeText: NSColor { .white }
        /// Badge alpha while offline.
        public static let badgeDimmedAlpha: CGFloat = 0.5
        /// Gallery stand-in for the panel's sidebar material, which does not render offscreen:
        /// the window background, translucent over `canvas` (which plays the desktop behind the panel).
        public static let panelStandIn = SwiftUI.Color(nsColor: .windowBackgroundColor).opacity(0.8)
        /// Gallery stand-in under --reduce-transparency: the opaque window background the
        /// material falls back to.
        public static let panelStandInOpaque = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// Gallery canvas behind multi-panel scenes.
        public static let canvas = SwiftUI.Color(nsColor: .underPageBackgroundColor)
        /// `light` under Aqua, `dark` under Dark Aqua (each with its high-contrast form).
        static func adaptive(light: NSColor, dark: NSColor) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
        }

        /// A queue card: near-white over the light panel, a faint lift over the dark one.
        public static let cardFill = adaptive(light: .white.withAlphaComponent(0.75), dark: .white.withAlphaComponent(0.07))
        /// A recently closed card, clearly quieter than an open one: over the dark panel almost
        /// no lift (`cardStrokeQuiet` draws its edge); over the light one a little lighter than the panel.
        public static let cardFillQuiet = adaptive(light: .white.withAlphaComponent(0.35), dark: .white.withAlphaComponent(0.015))
        public static let cardStroke = SwiftUI.Color.primary.opacity(0.08)
        /// A section header's count pill: a soft fill under primary digits.
        public static let countPillFill = SwiftUI.Color.primary.opacity(0.1)
        /// A recently closed card's hairline. Its fill is close to the panel's, so in light mode
        /// the line is a little firmer than `cardStroke`, or the card's edge would vanish.
        public static let cardStrokeQuiet = adaptive(light: .black.withAlphaComponent(0.14), dark: .white.withAlphaComponent(0.09))
        /// The card hairline under Increase Contrast.
        public static let cardStrokeContrast = SwiftUI.Color.primary.opacity(0.4)
        /// The selected card: an accent tint under an accent border.
        public static let cardSelectedFill = SwiftUI.Color.accentColor.opacity(0.14)
        public static let cardSelectedStroke = SwiftUI.Color.accentColor
        /// The monogram colours; `Monogram.colorIndex` picks one per project.
        public static let monogramPalette: [SwiftUI.Color] = [.blue, .indigo, .purple, .pink, .orange, .green, .teal, .brown]
        public static let monogramText = SwiftUI.Color.white
        /// A closed card's monogram.
        public static let monogramQuietOpacity: Double = 0.6
        public static func monogram(_ project: String) -> SwiftUI.Color {
            monogramPalette[Monogram.colorIndex(project) % monogramPalette.count]
        }
        /// The inset grouped steps list: near-white over the light panel, a faint lift over the dark one.
        public static let groupFill = adaptive(light: .white.withAlphaComponent(GroupLift.light),
                                               dark: .white.withAlphaComponent(GroupLift.dark))
        /// The white over the panel that `groupFill` lays down, by appearance.
        enum GroupLift {
            static let light: CGFloat = 0.8
            static let dark: CGFloat = 0.06
        }
        /// The required badge's ring: the required row's surface made opaque (the window
        /// background, the steps list's lift, then the required hue), so over the row the ring
        /// disappears and over an accent marker it draws a gap.
        public static let requiredBadgeRing = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var base = NSColor.white, accent = NSColor.systemBlue
            appearance.performAsCurrentDrawingAppearance {
                base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? base
                accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent
            }
            let lifted = base.blended(withFraction: dark ? GroupLift.dark : GroupLift.light, of: .white) ?? base
            return lifted.blended(withFraction: dark ? RequiredHue.dark : RequiredHue.light, of: accent) ?? lifted
        })
        public static let groupStroke = SwiftUI.Color.primary.opacity(0.07)
        /// An option list's hairline, and the picked option's tint.
        public static let optionStroke = SwiftUI.Color.primary.opacity(0.14)
        public static let optionSelected = SwiftUI.Color.accentColor.opacity(0.10)
        /// The blocking step's warning box.
        public static let warnFill = SwiftUI.Color.orange.opacity(0.12)
        public static let warnStroke = SwiftUI.Color.orange.opacity(0.35)
        /// The history bar's tint (a review lock that isn't a correction).
        public static let errorFill = SwiftUI.Color.red.opacity(0.10)
        /// The review's unified diff: a "−" line and a "+" line, and the changed words on them.
        /// The words also carry a strikethrough or weight, and each line its glyph, for colour-blind safety.
        public static let diffRemovedLine = SwiftUI.Color.red.opacity(0.08)
        public static let diffAddedLine = SwiftUI.Color.green.opacity(0.09)
        public static let diffRemovedWord = SwiftUI.Color.red.opacity(0.24)
        public static let diffAddedWord = SwiftUI.Color.green.opacity(0.26)
        /// A locked ask's unchanged steps, under the review bar.
        public static let lockedOpacity: Double = 0.55
        /// The app icon placeholder's gradient, top to bottom.
        public static let appIconTop = SwiftUI.Color.accentColor
        public static let appIconBottom = SwiftUI.Color.accentColor.opacity(0.7)
        public static let appIconSymbol = SwiftUI.Color.white
        /// A progress dot: the current page, and the others.
        public static let dotCurrent = SwiftUI.Color.accentColor
        public static let dotOther = AnyShapeStyle(.quaternary)
        /// A file row's icon when the file can't be opened here (missing, or on another Mac).
        public static let fileUnavailableOpacity: Double = 0.5
        /// A harness mark in "N more supported": found nowhere on this Mac.
        public static let harnessDimmedOpacity: Double = 0.45
        /// One colour per harness mark, keyed by the harness table's ids in `HarnessMark`. Each
        /// keeps white letters at 4:1 or better (`HarnessMarkTests`), in both appearances.
        public enum Harness {
            public static let claudeCode = NSColor(srgbRed: 0.78, green: 0.36, blue: 0.18, alpha: 1)
            public static let codex = NSColor(srgbRed: 0.30, green: 0.32, blue: 0.36, alpha: 1)
            public static let geminiCLI = NSColor(srgbRed: 0.15, green: 0.40, blue: 0.85, alpha: 1)
            public static let antigravity = NSColor(srgbRed: 0.33, green: 0.30, blue: 0.78, alpha: 1)
            public static let copilotCLI = NSColor(srgbRed: 0.53, green: 0.27, blue: 0.78, alpha: 1)
            public static let vscodeCopilot = NSColor(srgbRed: 0.0, green: 0.45, blue: 0.75, alpha: 1)
            public static let cursor = NSColor(srgbRed: 0.25, green: 0.24, blue: 0.58, alpha: 1)
            public static let opencode = NSColor(srgbRed: 0.0, green: 0.48, blue: 0.48, alpha: 1)
            public static let zed = NSColor(srgbRed: 0.04, green: 0.42, blue: 0.60, alpha: 1)
            public static let pi = NSColor(srgbRed: 0.18, green: 0.52, blue: 0.25, alpha: 1)
            public static let devin = NSColor(srgbRed: 0.0, green: 0.48, blue: 0.36, alpha: 1)
            public static let factory = NSColor(srgbRed: 0.62, green: 0.42, blue: 0.08, alpha: 1)
            public static let kiro = NSColor(srgbRed: 0.66, green: 0.20, blue: 0.56, alpha: 1)
            public static let amp = NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1)
            public static let cline = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 1)
            public static let goose = NSColor(srgbRed: 0.40, green: 0.46, blue: 0.14, alpha: 1)
            public static let junie = NSColor(srgbRed: 0.80, green: 0.22, blue: 0.40, alpha: 1)
            public static let warp = NSColor(srgbRed: 0.50, green: 0.32, blue: 0.22, alpha: 1)
        }
        /// The panel's backdrop material.
        public static var panelMaterial: NSVisualEffectView.Material { .sidebar }
    }

    /// Hook's own images, as files in Resources/MenuBar (`MenuBarGlyphImage` loads them).
    public enum Glyph {
        /// The outline hook: the menu bar while nothing new is waiting, and the app-icon placeholder.
        public static let menuBarIdle = "menubar-idle"
        /// A filled fish on the hook: an unseen ask. It replaces the red dot.
        public static let menuBarNew = "menubar-new"
        /// Both glyphs' size in points; the files are @1x and @2x.
        public static let menuBarSize = CGSize(width: 16, height: 18)
        /// The placeholder glyph on the app-icon tile while the bundle has no icon (dev builds).
        public static let appIconPlaceholderHeight: CGFloat = 36

        public static func name(_ glyph: MenuBarGlyph) -> String {
            switch glyph {
            case .idle: return menuBarIdle
            case .new: return menuBarNew
            }
        }
    }

    public enum Symbol {
        public static let now = "exclamationmark.circle.fill"
        public static let today = "clock.fill"
        public static let whenever = "tray.fill"
        public static func stepTodo(_ n: Int) -> String { "\(n).circle" }
        public static func stepCurrent(_ n: Int) -> String { "\(n).circle.fill" }
        public static let stepDone = "checkmark.circle.fill"
        /// The badge on a required item (owner pick 1).
        public static let requiredBadge = "circle.fill"
        public static let subTodo = "circle"
        public static let subCurrent = "circle.inset.filled"
        public static let subDone = "checkmark.circle.fill"
        public static let filter = "line.3.horizontal.decrease.circle"
        public static let filterOn = "line.3.horizontal.decrease.circle.fill"
        public static let clearFilter = "xmark.circle.fill"
        public static let verifyTodo = "checkmark.seal"
        public static let verifyCurrent = "checkmark.seal.fill"
        public static let verifyDone = "checkmark.seal.fill"
        public static let expect = "arrow.turn.down.right"
        public static let openLink = "arrow.up.forward.square"
        public static let back = "chevron.backward"
        public static let prev = "chevron.up"
        public static let next = "chevron.down"
        public static let refresh = "arrow.clockwise"
        public static let settings = "gearshape"
        public static let hide = "xmark"
        public static let draft = "pencil"
        public static let statusOK = "circle.fill"
        public static let statusDown = "exclamationmark.triangle.fill"
        public static let away = "moon.fill"
        public static let error = "exclamationmark.octagon.fill"
        public static let info = "info.circle.fill"
        public static let empty = "checkmark.circle"
        public static let offline = "wifi.exclamationmark"
        public static let notSetUp = "tray"
        public static let notFound = "questionmark.circle"
        /// Only when the menu-bar glyphs are missing from the bundle (`DS.Glyph`).
        public static let menuBarFallback = "checklist"
        public static let link = "link"
        /// The detail header's ask menu (Resume Session).
        public static let more = "ellipsis.circle"
        public static let warning = "exclamationmark.triangle.fill"
        /// Settings › Queue's Mailbox row: the mailbox speaks Hook's level, or doesn't.
        public static let mailboxOK = "checkmark.circle.fill"
        public static let mailboxBehind = "exclamationmark.triangle.fill"
        /// A step locked behind an unfinished blocking step.
        public static let locked = "lock.fill"
        /// A picked single option; a multi option's box, ticked and not.
        public static let optionPicked = "checkmark"
        public static let checkboxOn = "checkmark.square.fill"
        public static let checkboxOff = "square"
        public static let sent = "checkmark"
        /// A step question's answered line.
        public static let answered = "checkmark.circle.fill"
        public static let clearShortcut = "xmark.circle.fill"
        public static let disclosureClosed = "chevron.right"
        public static let disclosureOpen = "chevron.down"
        public static let tabGeneral = "gearshape"
        public static let tabPanel = "sidebar.right"
        public static let tabQueue = "tray"
        public static let tabNotifications = "bell"
        public static let tabAgents = "terminal"
        public static let tabDocuments = "doc.text"
        public static let tabPrivacy = "hand.raised"
        /// Settings › Agents: a harness's or a piece's state.
        public static let agentInstalled = "checkmark.circle.fill"
        public static let agentUpdate = "arrow.down.circle.fill"
        public static let agentEdited = "pencil.circle.fill"
        public static let agentNeedsYou = "exclamationmark.circle.fill"
        public static let agentBlocked = "exclamationmark.triangle.fill"
        public static let agentNotSetUp = "circle.dashed"
        public static let agentNone = "minus.circle"
        /// Settings' same-line icon buttons: Show in Finder, Check for Updates…, open an app
        /// or a System Settings pane, and show an ask.
        /// Save Diagnostics… in Settings › Privacy.
        public static let saveDiagnostics = "square.and.arrow.down"
        public static let reveal = "folder"
        public static let update = "arrow.down.circle"
        public static let openApp = "arrow.up.forward.app"
        public static let show = "arrow.right.circle"
        /// Setup window rows and the Done page.
        public static let setupSource = "tray.and.arrow.down"
        public static let setupMailbox = "server.rack"
        public static let setupMCP = "puzzlepiece.extension"
        public static let setupSkill = "book.closed"
        public static let setupHook = "arrowshape.turn.up.left"
        public static let setupClaudeMd = "doc.text"
        public static let setupRepo = "folder"
        public static let setupNotifications = "bell.badge"
        public static let setupSound = "speaker.wave.2"
        public static let setupShortcut = "keyboard"
        public static let setupLogin = "power"
        public static let setupTestAsk = "paperplane"
        public static let setupDone = "checkmark.circle.fill"
        public static let setupSupport = "heart"
        public static let copy = "doc.on.doc"
        /// A correction waits for review: the bar, and the queue card's label.
        public static let corrected = "pencil.circle.fill"
        public static let correctedRow = "pencil.circle"
        /// The ask's history failed its checks.
        public static let historyChanged = "exclamationmark.triangle"
        /// Use Version N when it asks for Touch ID.
        public static let presence = "touchid"
        public static let lookCloser = "exclamationmark.triangle.fill"
        /// A step the pending correction adds.
        public static let stepAdded = "plus.circle"
        /// This Mac's owner key.
        public static let ownerKey = "person.badge.key.fill"
        /// Report a Problem on a step, and a step with a report waiting for a correction.
        public static let report = "exclamationmark.bubble"
        public static let reported = "exclamationmark.bubble.fill"
        /// The "?" beside a label: outlined and small (owner pick 2), never the stock filled HelpLink.
        public static let helpOutline = "questionmark.circle"
    }

    public enum Control {
        public static let action: ControlSize = .large
        public static let form: ControlSize = .regular
        public static let inline: ControlSize = .small
    }

    public enum Motion {
        public static let push = Animation.easeOut(duration: 0.22)
        /// A setup page pushing in.
        public static let page = Animation.easeInOut(duration: 0.32)
        public static let step = Animation.easeInOut(duration: 0.20)
        public static let reveal = Animation.easeOut(duration: 0.18)
        public static let reduced = Animation.easeOut(duration: 0.12)
        /// The app-icon placeholder's one bounce: up to `bounceScale`, then back.
        public static let bounceScale: CGFloat = 1.15
        public static let bounceUp: TimeInterval = 0.15
        public static let bounceSettle: TimeInterval = 0.3
        public static let slideIn: TimeInterval = 0.25
        public static let fade: TimeInterval = 0.12
        public static let snap: TimeInterval = 0.20
        public static let redockDebounce: TimeInterval = 0.25
        public static let wakeRecheck: TimeInterval = 1.0
        public static let copiedFor: TimeInterval = 1.5
        public static let undoHold: TimeInterval = 10
        /// How long the reply caption reads "Sent 10:42" after a send.
        public static let sentHold: TimeInterval = 4
        /// How long a transient Notice ("This ask is no longer open.") stays.
        public static let noticeHold: TimeInterval = 8
    }

    /// Store and Settings timings that are not animations.
    public enum Timing {
        /// How far back a closed ask still shows under "Closed today".
        public static let closedWindow: TimeInterval = 24 * 3600
        /// How old the last mailbox list may be before showing the panel lists again.
        public static let staleList: TimeInterval = 5
        /// The shortest gap between two refreshes made by a link check.
        public static let linkRecheck: TimeInterval = 5
        /// How often held-back closes are checked for being due.
        public static let holdTick: TimeInterval = 1
        /// How often Settings › Agents' "Last call" relative time re-renders.
        public static let lastCallRefresh: TimeInterval = 30
        /// How long a detail fetch, or the first list after a swap, waits before "Couldn't load" or "Still trying…".
        public static let detailLoadTimeout: TimeInterval = 10
        /// How long tick changes on an ask with requirements wait before they go to the Pond, so
        /// a run of ticks goes as one progress call.
        public static let progressDebounce: TimeInterval = 0.5
        /// How long a Done right after launch waits for the Pond's version check before it goes
        /// without its ticks (the Pond may then refuse it, and say so).
        public static let pondWait: TimeInterval = 5
    }

    /// The animation to use: `animation`, or `Motion.reduced` under Reduce Motion.
    public static func motion(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? Motion.reduced : animation
    }

    /// An AppKit animation length under Reduce Motion: frame moves (snap, fade) become
    /// instant, and the slide-in becomes a 0.12 s fade at the docked frame.
    public static func appKitDuration(_ seconds: TimeInterval, reduce: Bool) -> TimeInterval {
        guard reduce else { return seconds }
        return seconds == Motion.slideIn ? Motion.fade : 0
    }

    @MainActor public static func appKitDuration(_ seconds: TimeInterval) -> TimeInterval {
        appKitDuration(seconds, reduce: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

/// Animates `value` changes with `animation`, or with `DS.Motion.reduced` under Reduce Motion.
/// `.modifier(Motion(DS.Motion.reveal, value: expanded))`, or `.motion(DS.Motion.reveal, value: expanded)`.
public struct Motion<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ animation: Animation, value: Value) {
        self.animation = animation
        self.value = value
    }

    public func body(content: Content) -> some View {
        content.animation(DS.motion(animation, reduce: reduce), value: value)
    }
}

extension View {
    public func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(Motion(animation, value: value))
    }
}
