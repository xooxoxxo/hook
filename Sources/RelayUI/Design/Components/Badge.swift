import AppKit
import RelayCore

/// Where the badge sits: over the symbol's top-right corner, clamped inside the button.
public enum BadgeGeometry {
    public static func size(for badge: MenuBarBadge) -> CGSize {
        switch badge {
        case .none: return .zero
        case .dot: return CGSize(width: DS.Metric.badgeDot, height: DS.Metric.badgeDot)
        case .number: return CGSize(width: DS.Metric.badge, height: DS.Metric.badge)
        }
    }

    public static func frame(for badge: MenuBarBadge, in buttonBounds: CGRect) -> CGRect {
        frame(for: badge, in: buttonBounds, imageRect: buttonBounds, flipped: false)
    }

    /// Positioned from the bounds and the image rect, so taller menu bars need no special case.
    public static func frame(for badge: MenuBarBadge, in bounds: CGRect, imageRect image: CGRect, flipped: Bool) -> CGRect {
        guard badge != .none else { return .zero }
        let size = self.size(for: badge).width
        let x = min(max(image.maxX - size * 0.6, bounds.minX), bounds.maxX - size)
        let y = flipped ? image.minY - size * 0.35 : image.maxY - size * 0.65
        return CGRect(x: x, y: min(max(y, bounds.minY), bounds.maxY - size), width: size, height: size)
    }
}

/// The red badge: a 13 pt circle with a white digit, or a plain 7 pt dot. Not an
/// accessibility element (the status button's label carries the count); never takes clicks.
public final class BadgeView: NSView {
    public var badge: MenuBarBadge = .none {
        didSet {
            isHidden = badge == .none
            if badge != oldValue { needsDisplay = true }
        }
    }

    public var dimmed = false {
        didSet { alphaValue = dimmed ? 0.5 : 1 }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BadgeView is created in code")
    }

    public override func isAccessibilityElement() -> Bool { false }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard badge != .none else { return }
        DS.Color.badge.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard case .number(let count) = badge, let context = NSGraphicsContext.current?.cgContext else { return }
        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: DS.Font.badgeDigit,
            .foregroundColor: NSColor.white,
        ])
        // Centre the digit's ink, not its line box, so it looks optically centred.
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
