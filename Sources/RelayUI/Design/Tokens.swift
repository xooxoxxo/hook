import AppKit
import SwiftUI

// Design/Tokens.swift (design §3.1). Every size, colour, font, symbol and duration the views use lives here; scripts/check-tokens.sh fails a literal anywhere else.

public enum DS {
    public enum Space {
        public static let rowLine: CGFloat = 4
        public static let rowInsetV: CGFloat = 6
        /// Leading/trailing List row inset. The stock `.sidebar` List already places row content
        /// 16 pt (= gutter) from the panel edge at inset 0 (measured, macOS 15), so 0 lands row text on the gutter.
        public static let rowInsetH: CGFloat = 0
        /// Stock sidebar section headers start 14 pt from the panel edge (measured); this nudge puts them on the gutter.
        public static let sectionHeaderLead: CGFloat = 2
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
        /// GroupBox content inset (5 pt, measured) + currentStep: the current step's box bleeds out by this
        /// so its marker and text stay on the todo/done column.
        public static let currentBleed: CGFloat = 9
        public static let emptyLine: CGFloat = 24
        public static let popover: CGFloat = 16
    }

    public enum Metric {
        public static let panelWidth: CGFloat = 380
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
        public static let welcomeWidth: CGFloat = 480
        public static let badge: CGFloat = 13
        public static let badgeDot: CGFloat = 7
        public static let dragThreshold: CGFloat = 3
        public static let recorderMin: CGFloat = 130
        /// The List's `defaultMinListRowHeight`, = hit.
        public static let rowMinHeight: CGFloat = 28
    }

    public enum Font {
        /// Gallery-only text multiplier for --xl. macOS ignores .dynamicTypeSize for text styles, so RelayGallery sets this once before rendering. Relay never sets it, and at 1 every token is exactly its stock text style (§3.1).
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
        public static var body: SwiftUI.Font { style(.body, .body) }
        public static var currentAction: SwiftUI.Font { style(.headline, .headline) }
        public static var meta: SwiftUI.Font { style(.subheadline, .subheadline) }
        public static var prose: SwiftUI.Font { style(.callout, .callout) }
        public static var code: SwiftUI.Font { style(.callout, .callout).monospaced() }
        public static var caption: SwiftUI.Font { style(.caption, .caption1) }
        public static var welcomeTitle: SwiftUI.Font { style(.title2, .title2).weight(.semibold) }
        public static var badgeDigit: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .bold) }
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
        public static let codeFill = AnyShapeStyle(.quaternary.opacity(0.6))
        public static let bar = Material.bar
        public static var badge: NSColor { .systemRed }
        public static var badgeText: NSColor { .white }
        /// Badge alpha while offline (§4.10).
        public static let badgeDimmedAlpha: CGFloat = 0.5
        /// Gallery stand-in for the panel's sidebar material, which does not render offscreen:
        /// the window background, translucent over `canvas` (which plays the desktop behind the panel).
        public static let panelStandIn = SwiftUI.Color(nsColor: .windowBackgroundColor).opacity(0.8)
        /// Gallery stand-in under --reduce-transparency: the opaque window background the
        /// material falls back to (§3.5).
        public static let panelStandInOpaque = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// Gallery canvas behind multi-panel scenes.
        public static let canvas = SwiftUI.Color(nsColor: .underPageBackgroundColor)
        /// The panel's backdrop material.
        public static var panelMaterial: NSVisualEffectView.Material { .sidebar }
    }

    public enum Symbol {
        public static let now = "exclamationmark.circle.fill"
        public static let today = "clock.fill"
        public static let whenever = "tray.fill"
        public static func stepTodo(_ n: Int) -> String { "\(n).circle" }
        public static func stepCurrent(_ n: Int) -> String { "\(n).circle.fill" }
        public static let stepDone = "checkmark.circle.fill"
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
        public static let menuBar = "checklist"
        public static let link = "link"
        public static let warning = "exclamationmark.triangle.fill"
        public static let sent = "checkmark"
        public static let clearShortcut = "xmark.circle.fill"
        public static let disclosureClosed = "chevron.right"
        public static let disclosureOpen = "chevron.down"
        public static let tabGeneral = "gearshape"
        public static let tabPanel = "sidebar.right"
        public static let tabQueue = "tray"
        public static let tabNotifications = "bell"
        public static let tabConnect = "link"
    }

    public enum Control {
        public static let action: ControlSize = .large
        public static let form: ControlSize = .regular
        public static let inline: ControlSize = .small
    }

    public enum Motion {
        public static let push = Animation.easeOut(duration: 0.22)
        public static let step = Animation.easeInOut(duration: 0.20)
        public static let reveal = Animation.easeOut(duration: 0.18)
        public static let reduced = Animation.easeOut(duration: 0.12)
        public static let slideIn: TimeInterval = 0.25
        public static let fade: TimeInterval = 0.12
        public static let snap: TimeInterval = 0.20
        public static let redockDebounce: TimeInterval = 0.25
        public static let wakeRecheck: TimeInterval = 1.0
        public static let copiedFor: TimeInterval = 1.5
        public static let undoHold: TimeInterval = 10
        /// How long the reply caption reads "Sent 10:42" after a send.
        public static let sentHold: TimeInterval = 4
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
        /// How often the Connect tab's "Last call" relative time re-renders.
        public static let lastCallRefresh: TimeInterval = 30
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
