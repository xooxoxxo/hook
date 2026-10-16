import AppKit

/// A bitmap as 0xRRGGBBAA pixels, row 0 at the top.
public struct InkBitmap: Sendable {
    public let width: Int
    public let height: Int
    /// Pixels per point.
    public let scale: CGFloat
    public let pixels: [UInt32]

    public init(width: Int, height: Int, scale: CGFloat, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.scale = scale
        self.pixels = pixels
    }

    public static func rgba(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
    }

    /// Redraws `rep` into a known RGBA8 layout first, so any capture format works.
    public init?(_ rep: NSBitmapImageRep) {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, rep.size.width > 0,
              let normal = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: normal) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = normal.bitmapData else { return nil }
        var pixels = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w * 4 + x * 4
                pixels[y * w + x] = Self.rgba(data[i], data[i + 1], data[i + 2], data[i + 3])
            }
        }
        self.init(width: w, height: h, scale: CGFloat(w) / rep.size.width, pixels: pixels)
    }

    func differs(_ a: UInt32, _ b: UInt32, threshold: Int) -> Bool {
        for shift in [24, 16, 8] as [UInt32] {
            let ca = Int((a >> shift) & 0xFF), cb = Int((b >> shift) & 0xFF)
            if abs(ca - cb) > threshold { return true }
        }
        return false
    }
}

/// Where ink starts and ends inside a probe's rect. The rect's top-left pixel is the background.
public enum InkScan {
    public static func firstInkX(_ bitmap: InkBitmap, in rect: CGRect, threshold: Int) -> CGFloat? {
        inkColumns(bitmap, rect, threshold).first.map { CGFloat($0) / bitmap.scale }
    }

    public static func lastInkX(_ bitmap: InkBitmap, in rect: CGRect, threshold: Int) -> CGFloat? {
        inkColumns(bitmap, rect, threshold).last.map { CGFloat($0 + 1) / bitmap.scale }
    }

    public static func centreX(_ bitmap: InkBitmap, in rect: CGRect, threshold: Int) -> CGFloat? {
        guard let first = firstInkX(bitmap, in: rect, threshold: threshold),
              let last = lastInkX(bitmap, in: rect, threshold: threshold) else { return nil }
        return (first + last) / 2
    }

    static func inkColumns(_ bitmap: InkBitmap, _ rect: CGRect, _ threshold: Int) -> [Int] {
        let x0 = max(0, Int((rect.minX * bitmap.scale).rounded(.down)))
        let x1 = min(bitmap.width, Int((rect.maxX * bitmap.scale).rounded(.up)))
        let y0 = max(0, Int((rect.minY * bitmap.scale).rounded(.down)))
        let y1 = min(bitmap.height, Int((rect.maxY * bitmap.scale).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return [] }
        let background = bitmap.pixels[y0 * bitmap.width + x0]
        return (x0..<x1).filter { x in
            (y0..<y1).contains { y in bitmap.differs(bitmap.pixels[y * bitmap.width + x], background, threshold: threshold) }
        }
    }
}

public enum AlignmentRule: Equatable, Sendable {
    case leading(ProbeRole, x: CGFloat, tolerance: CGFloat)
    case trailing(ProbeRole, x: CGFloat, tolerance: CGFloat)
    case sameCentre(ProbeRole, tolerance: CGFloat)
    case sameLeading(ProbeRole, tolerance: CGFloat)
    case sameTrailingPerGroup(ProbeRole, tolerance: CGFloat)

    var role: ProbeRole {
        switch self {
        case .leading(let r, _, _), .trailing(let r, _, _), .sameCentre(let r, _), .sameLeading(let r, _),
             .sameTrailingPerGroup(let r, _):
            return r
        }
    }
}

extension AlignmentRule: CustomStringConvertible {
    public var description: String {
        let f: (CGFloat) -> String = AlignmentCheck.format
        switch self {
        case let .leading(r, x, t): return "leading(\(r.rawValue), x: \(f(x)), tolerance: \(f(t)))"
        case let .trailing(r, x, t): return "trailing(\(r.rawValue), x: \(f(x)), tolerance: \(f(t)))"
        case let .sameCentre(r, t): return "sameCentre(\(r.rawValue), tolerance: \(f(t)))"
        case let .sameLeading(r, t): return "sameLeading(\(r.rawValue), tolerance: \(f(t)))"
        case let .sameTrailingPerGroup(r, t): return "sameTrailingPerGroup(\(r.rawValue), tolerance: \(f(t)))"
        }
    }
}
public struct AlignmentFailure: Equatable, Sendable, CustomStringConvertible {
    public var rule: AlignmentRule
    public var detail: String

    public init(rule: AlignmentRule, detail: String) {
        self.rule = rule
        self.detail = detail
    }

    public var description: String { "\(rule): \(detail)" }
}

public enum AlignmentCheck {
    /// Ink differs from the background by more than this in some channel (0–255).
    static let threshold = 48

    public static func verify(_ probes: [ProbeFrame], bitmap: InkBitmap, rules: [AlignmentRule]) -> [AlignmentFailure] {
        var failures: [AlignmentFailure] = []
        for rule in rules {
            let mine = probes.filter { $0.role == rule.role }
            guard !mine.isEmpty else {
                failures.append(AlignmentFailure(rule: rule, detail: "no \(rule.role.rawValue) probe"))
                continue
            }
            func measure(_ scan: (InkBitmap, CGRect, Int) -> CGFloat?) -> [(ProbeFrame, CGFloat)]? {
                var values: [(ProbeFrame, CGFloat)] = []
                for p in mine {
                    guard let value = scan(bitmap, p.frame, threshold) else {
                        failures.append(AlignmentFailure(rule: rule, detail: "no ink in \(p.role.rawValue) at \(format(rect: p.frame))"))
                        return nil
                    }
                    values.append((p, value))
                }
                return values
            }
            switch rule {
            case let .leading(_, x, tolerance):
                for (p, value) in measure(InkScan.firstInkX) ?? [] where abs(value - x) > tolerance {
                    failures.append(AlignmentFailure(rule: rule, detail: "starts at \(format(value)), expected \(format(x)) ± \(format(tolerance)) (\(format(rect: p.frame)))"))
                }
            case let .trailing(_, x, tolerance):
                for (p, value) in measure(InkScan.lastInkX) ?? [] where abs(value - x) > tolerance {
                    failures.append(AlignmentFailure(rule: rule, detail: "ends at \(format(value)), expected \(format(x)) ± \(format(tolerance)) (\(format(rect: p.frame)))"))
                }
            case let .sameCentre(_, tolerance):
                let values = measure(InkScan.centreX)
                spread(values, tolerance, rule, "centres", &failures)
            case let .sameLeading(_, tolerance):
                let values = measure(InkScan.firstInkX)
                spread(values, tolerance, rule, "starts", &failures)
            case let .sameTrailingPerGroup(_, tolerance):
                guard let values = measure(InkScan.lastInkX) else { continue }
                for group in Set(values.map(\.0.group)).sorted() {
                    spread(values.filter { $0.0.group == group }, tolerance, rule, "ends in \(group)", &failures)
                }
            }
        }
        return failures
    }

    private static func spread(_ values: [(ProbeFrame, CGFloat)]?, _ tolerance: CGFloat, _ rule: AlignmentRule,
                               _ what: String, _ failures: inout [AlignmentFailure]) {
        guard let values, let low = values.map(\.1).min(), let high = values.map(\.1).max() else { return }
        if high - low > tolerance {
            failures.append(AlignmentFailure(rule: rule, detail: "\(what) range \(format(low))–\(format(high)), more than \(format(tolerance)) apart"))
        }
    }

    static func format(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }

    static func format(rect: CGRect) -> String {
        "(\(format(rect.minX)), \(format(rect.minY)), \(format(rect.width))×\(format(rect.height)))"
    }
}
