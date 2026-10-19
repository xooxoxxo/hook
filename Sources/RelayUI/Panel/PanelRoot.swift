import AppKit
import RelayCore
import SwiftUI

/// Gallery-only overrides; the app never sets them. A fixed clock for ages, the two
/// `@AppStorage` disclosures, and a full-height detail (a ScrollView reports no height
/// offscreen), so renders are repeatable and never write UserDefaults.
public struct PanelGalleryOverrides: Equatable, Sendable {
    public var now: Date?
    public var closedExpanded: Bool?
    public var fromExpanded: Bool?
    public var fullHeight: Bool?

    public init(now: Date? = nil, closedExpanded: Bool? = nil, fromExpanded: Bool? = nil, fullHeight: Bool? = nil) {
        self.now = now
        self.closedExpanded = closedExpanded
        self.fromExpanded = fromExpanded
        self.fullHeight = fullHeight
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

/// The panel's one column (design §4.6). The queue is always mounted; an open ask pushes
/// its detail on top. While the detail shows, the list is transparent, ignores clicks and
/// is hidden from VoiceOver, but it is never removed, so its selection, scroll offset and
/// focus survive the push, a poll that re-sections and a grouping switch.
public struct PanelRoot<Model: PanelViewModel>: View {
    @ObservedObject private var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelGallery) private var gallery

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// True while an ask is open in the detail, whether or not it is in the list.
    public static func showsDetail(_ navigation: PanelNavigation) -> Bool {
        navigation.selectedID != nil
    }

    @ViewBuilder public var body: some View {
        // A full-height gallery render sizes the scene to the detail; the queue's List would
        // take every point it is offered (no app path sets fullHeight).
        if gallery.fullHeight == true, let detailID = model.navigation.selectedID {
            DetailView(model: model, id: detailID)
        } else {
            column
        }
    }

    private var column: some View {
        let detailID = model.navigation.selectedID
        let detailShown = Self.showsDetail(model.navigation)
        return ZStack(alignment: .top) {
            QueueView(model: model)
                .opacity(detailShown ? 0 : 1)
                .allowsHitTesting(!detailShown)
                .accessibilityHidden(detailShown)
            if let detailID {
                DetailView(model: model, id: detailID)
                    .id(detailID)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(DS.motion(DS.Motion.push, reduce: reduceMotion), value: detailID)
        .modifier(PanelKeys(model: model))
    }
}
