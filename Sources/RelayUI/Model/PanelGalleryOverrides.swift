import Foundation
import SwiftUI

/// Gallery-only overrides; the app never sets them. A fixed clock for ages, the two
/// `@AppStorage` disclosures, and a full-height detail (a ScrollView reports no height
/// offscreen), so renders are repeatable and never write UserDefaults.
public struct PanelGalleryOverrides: Equatable, Sendable {
    public var now: Date?
    public var closedExpanded: Bool?
    public var fromExpanded: Bool?
    public var fullHeight: Bool?
    /// The reply's History disclosure.
    public var historyExpanded: Bool?
    /// The Messages section's "Message the session" disclosure.
    public var messagesExpanded: Bool?
    /// The clock a step answer's time is shown in (the gallery renders in UTC, en_GB).
    public var locale: Locale?
    public var timeZone: TimeZone?

    public init(now: Date? = nil, closedExpanded: Bool? = nil, fromExpanded: Bool? = nil, fullHeight: Bool? = nil,
                historyExpanded: Bool? = nil, locale: Locale? = nil, timeZone: TimeZone? = nil,
                messagesExpanded: Bool? = nil) {
        self.now = now
        self.closedExpanded = closedExpanded
        self.fromExpanded = fromExpanded
        self.fullHeight = fullHeight
        self.historyExpanded = historyExpanded
        self.messagesExpanded = messagesExpanded
        self.locale = locale
        self.timeZone = timeZone
    }
}

private struct PanelGalleryOverridesKey: EnvironmentKey {
    static let defaultValue = PanelGalleryOverrides()
}

extension EnvironmentValues {
    public var panelGallery: PanelGalleryOverrides {
        get { self[PanelGalleryOverridesKey.self] }
        set { self[PanelGalleryOverridesKey.self] = newValue }
    }
}
