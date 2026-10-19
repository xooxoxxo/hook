import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The gallery's mailbox source key (generic host, never a real one).
let galleryMailboxKey = "mailbox:mailbox.example:8790#personal"

/// "Mailbox · ready", from the same logic the app uses.
let readyStatus = PanelStatus.make(StatusInputs(sourceKey: galleryMailboxKey, reachable: true, loadedOnce: true))

/// A 380 pt panel scene rendered through `PanelRoot`, on the fixed gallery clock.
@MainActor func panelScene(_ name: String, _ model: FixturePanelModel, height: CGFloat? = 820,
                           rules: [AlignmentRule] = []) -> GalleryScene {
    panelScene(name, model, height: height, rules: rules, overrides: PanelGalleryOverrides(now: GalleryFixtures.now))
}

/// The same, with gallery overrides (closed group or From expanded, full-height detail).
@MainActor func panelScene(_ name: String, _ model: FixturePanelModel, height: CGFloat?,
                           rules: [AlignmentRule], overrides: PanelGalleryOverrides) -> GalleryScene {
    GalleryScene(
        name: name, size: .panel(height: height), standIn: true, rules: rules,
        view: { AnyView(PanelRoot(model: model).environment(\.panelGallery, overrides)) },
        appKit: nil)
}

@MainActor let queueScenes: [GalleryScene] = [
    panelScene("queue", FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false), status: readyStatus)),
]
