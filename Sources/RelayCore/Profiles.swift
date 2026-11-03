import Foundation

/// One queue Hook can show: This Mac, or the saved Pond. Pond areas (0.13) plug in here.
public struct Profile: Equatable, Sendable, Identifiable {
    public var kind: SourceKind
    public var name: String
    public var current: Bool

    public init(kind: SourceKind, name: String, current: Bool) {
        self.kind = kind
        self.name = name
        self.current = current
    }

    public var id: String { kind.rawValue }
}

/// The status bar's profile switcher: the profiles, which one is shown, and whether the
/// switch can save (config.json read-only disables it).
public struct ProfileMenu: Equatable, Sendable {
    public var profiles: [Profile]
    /// config.json has an error or is missing: the switch can't save, so it's off.
    public var readOnly: Bool
    /// A Pond URL and token file are saved; otherwise the menu offers "Set Up a Pond…".
    public var pondSaved: Bool

    public init(profiles: [Profile], readOnly: Bool, pondSaved: Bool) {
        self.profiles = profiles
        self.readOnly = readOnly
        self.pondSaved = pondSaved
    }

    public static let empty = ProfileMenu(profiles: [Profile(kind: .local, name: thisMac, current: false)],
                                          readOnly: true, pondSaved: false)

    public static let thisMac = "This Mac"
    public static let noQueue = "No Queue"
    public static let readOnlyHelp = "config.json can't be saved right now, so the profile can't change. Fix it in Settings › Queue."

    public var current: Profile? { profiles.first(where: \.current) }

    /// The menu's title: the shown profile's name.
    public var label: String { current?.name ?? Self.noQueue }

    /// This Mac always; the Pond once its URL and token file are saved, named by its
    /// context in title case ("personal" → "Personal").
    public static func make(config: RelayConfig?, readOnly: Bool = false) -> ProfileMenu {
        guard let config else { return ProfileMenu(profiles: empty.profiles, readOnly: true, pondSaved: false) }
        let resolved = config.resolvedSource()
        let pondSaved = !(config.mailboxURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(config.tokenFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var profiles = [Profile(kind: .local, name: thisMac, current: resolved == .local)]
        if pondSaved {
            var onPond = false
            if case .mailbox = resolved { onPond = true }
            profiles.append(Profile(kind: .mailbox, name: name(context: config.context), current: onPond))
        }
        return ProfileMenu(profiles: profiles, readOnly: readOnly, pondSaved: pondSaved)
    }

    /// "home-lab" → "Home Lab": dashes and underscores become spaces, and each word starts
    /// upper case (the rest is kept, so "ACME" stays). An empty context reads "Pond".
    public static func name(context: String) -> String {
        let words = context.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "Pond" }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "Profile Personal. Status: Pond, ready".
    public static func accessibilityText(_ menu: ProfileMenu, status: PanelStatus) -> String {
        "Profile \(menu.label). Status: \(status.spoken)"
    }
}
