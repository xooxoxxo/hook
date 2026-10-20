import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// Every control in a section ends on one trailing edge (§3.5). SettingsRow probes its
/// help slot as `.settingsTrailing`; the grouped Form gives every section the same width.
let settingsRules: [AlignmentRule] = [.sameTrailingPerGroup(.settingsTrailing, tolerance: 1)]

/// A Settings scene: the real toolbar-tab window chrome around `view` on `tab`.
@MainActor func settingsScene<V: View>(_ name: String, tab: SettingsTabID, rules: [AlignmentRule] = settingsRules,
                                       _ view: @escaping @MainActor () -> V) -> GalleryScene {
    GalleryScene(name: name, size: .settings(tab: tab.rawValue), standIn: false, rules: rules,
                 view: { AnyView(view()) }, appKit: nil)
}

/// One entry per Settings tab state.
@MainActor var settingsScenes: [GalleryScene] {
    [
        settingsScene("settings-general", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot()))
        },
        settingsScene("settings-readonly", tab: .general) {
            GeneralTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(readOnly: true)))
        },
        settingsScene("settings-panel", tab: .panel) {
            PanelTab(model: FixtureSettingsModel(settings: SettingsFixtures.snapshot(displays: [
                DisplayOption(id: nil, title: "Main display", connected: true),
                DisplayOption(id: "D1", title: "Studio Display", connected: true),
                DisplayOption(id: "D2", title: "Projector (not connected)", connected: false),
            ])))
        },
    ]
}
