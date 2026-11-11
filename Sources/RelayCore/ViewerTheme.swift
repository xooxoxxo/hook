import Foundation

/// `viewer` in config.json: how Hook's document viewer looks. A preset palette, the
/// owner's own colour for any role on top of it, how wide the reading column may grow,
/// and a text size step. Every key is optional; a config without `viewer` reads as
/// today's look (the system palette, full width, the default size).
public struct ViewerTheme: Sendable, Equatable, Codable {
    /// The palette a theme starts from.
    public enum Preset: String, Sendable, Equatable, Codable, CaseIterable {
        /// The system colours, light or dark with the appearance (the original look).
        case system
        /// Near-black on white, whatever the appearance.
        case paper
        /// Brown on cream, whatever the appearance.
        case sepia
        /// Light grey on near-black, whatever the appearance.
        case night

        public var title: String {
            switch self {
            case .system: "System"
            case .paper: "Paper"
            case .sepia: "Sepia"
            case .night: "Night"
            }
        }
    }

    /// A colour the owner can set.
    public enum Role: String, Sendable, Equatable, Codable, CaseIterable {
        case background, text, headings, links, code, rules

        public var title: String {
            switch self {
            case .background: "Background"
            case .text: "Text"
            case .headings: "Headings"
            case .links: "Links"
            case .code: "Code background"
            case .rules: "Quote bar and rules"
            }
        }
    }

    /// How wide the reading column may grow.
    public enum Width: String, Sendable, Equatable, Codable, CaseIterable {
        /// The window's width, less the page inset (the default).
        case full
        /// A wide column, centred.
        case wide
        /// The original reading column, centred.
        case narrow

        public var title: String {
            switch self {
            case .full: "Full"
            case .wide: "Wide"
            case .narrow: "Narrow"
            }
        }
    }

    /// The text size steps, in points from the default.
    public static let textSizeSteps = -2...6

    public var preset: Preset
    /// The owner's colours, `#rrggbb`, by role; a role without one takes the preset's.
    public var colors: [Role: String]
    public var width: Width
    /// Points added to the default text size, within `textSizeSteps`.
    public var textSize: Int

    enum CodingKeys: String, CodingKey {
        case preset, colors, width, textSize
    }

    public init(preset: Preset = .system, colors: [Role: String] = [:], width: Width = .full, textSize: Int = 0) {
        self.preset = preset
        self.colors = colors.compactMapValues(Self.hex)
        self.width = width
        self.textSize = min(max(textSize, Self.textSizeSteps.lowerBound), Self.textSizeSteps.upperBound)
    }

    /// A missing, null, wrong-typed or unknown value takes its default; a colour that isn't
    /// `#rgb` or `#rrggbb`, or names no role, is dropped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = c.lenient([String: JSONValue].self, .colors) ?? [:]
        var colors: [Role: String] = [:]
        for (key, value) in raw {
            guard let role = Role(rawValue: key), case .string(let text) = value else { continue }
            colors[role] = text
        }
        self.init(
            preset: c.lenient(String.self, .preset).flatMap(Preset.init(rawValue:)) ?? .system,
            colors: colors,
            width: c.lenient(String.self, .width).flatMap(Width.init(rawValue:)) ?? .full,
            textSize: c.lenient(Int.self, .textSize) ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset.rawValue, forKey: .preset)
        try c.encode(Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }), forKey: .colors)
        try c.encode(width.rawValue, forKey: .width)
        try c.encode(textSize, forKey: .textSize)
    }

    /// The value config.json stores under `viewer` (only what differs from the default).
    public var configValue: [String: Any] {
        var out: [String: Any] = [:]
        if preset != .system { out["preset"] = preset.rawValue }
        if !colors.isEmpty {
            out["colors"] = Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) })
        }
        if width != .full { out["width"] = width.rawValue }
        if textSize != 0 { out["textSize"] = textSize }
        return out
    }

    /// The theme with `role` set to `hex`, or back to the preset's colour when nil.
    public func setting(_ role: Role, to hex: String?) -> ViewerTheme {
        var next = self
        next.colors[role] = hex.flatMap(Self.hex)
        return next
    }

    /// `#rgb` or `#rrggbb` (any case) as lowercase `#rrggbb`; nil for anything else.
    public static func hex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 6: return "#" + digits
        case 3: return "#" + digits.map { "\($0)\($0)" }.joined()
        default: return nil
        }
    }

    /// The red, green and blue of a `#rrggbb` colour, 0…1.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normal = Self.hex(hex), let value = UInt32(normal.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// True when `hex` is a dark colour (WCAG relative luminance under 0.4): the viewer
    /// window's title bar goes dark over it.
    public static func isDark(_ hex: String) -> Bool {
        guard let rgb = components(hex) else { return false }
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        return luminance < 0.4
    }
}
