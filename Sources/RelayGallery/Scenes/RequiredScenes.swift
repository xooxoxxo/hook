import AppKit
import RelayCore
import RelayUI
import SwiftUI

// Required before Done (Pond 1.3.0, owner pick 1): Done off while something is left, no
// caption or checklist, the required items marked by a badge and a hue. Generic text only.

/// `snapshot` open in the detail, full height; `open` holds upcoming rows opened by hand.
@MainActor private func requiredScene(_ name: String, _ snapshot: DetailSnapshot, open: Set<String> = [],
                                      rules: [AlignmentRule]) -> GalleryScene {
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    model.expandedTodo[snapshot.id] = open
    let overrides = PanelGalleryOverrides(now: GalleryFixtures.now, fromExpanded: false, fullHeight: true,
                                          locale: galleryGB, timeZone: galleryUTC)
    return panelScene(name, model, height: nil, rules: rules, overrides: overrides)
}

@MainActor var requiredScenes: [GalleryScene] {
    [
        // Step 1 required and ticked (no mark); 2, 3 and 4a left (4 opened to show 4a); the
        // reply and a message left: every one marked, Done off.
        requiredScene("detail-required-left", RequiredFixtures.full(ready: false), open: ["4"], rules: stepColumnRules),
        // The same ask with everything finished: no marks, Done on, no caption.
        requiredScene("detail-required-ready", RequiredFixtures.full(ready: true), rules: topColumnRules),
        // Only a message left, on an ask with a reply prompt: the field is inline and marked.
        requiredScene("detail-required-messages", RequiredFixtures.messageLeft, rules: topColumnRules),
        // Only the reply left: the reply prompt is marked.
        requiredScene("detail-required-reply", RequiredFixtures.replyLeft, rules: topColumnRules),
    ]
}
