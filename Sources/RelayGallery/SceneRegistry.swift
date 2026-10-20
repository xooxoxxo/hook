import AppKit
import RelayUI
import SwiftUI

/// How a scene is captured.
enum SceneSize {
    /// Panel width; nil height = the content's own height, uncapped.
    case panel(height: CGFloat?)
    case wide(width: CGFloat, height: CGFloat?)
    /// One Settings tab inside a real `.toolbar` tab window; `tab` is a `SettingsTabID` raw value.
    case settings(tab: String)
    /// An AppKit view (the menu-bar badge strip).
    case appKit(NSSize)
}

struct GalleryScene {
    let name: String
    let size: SceneSize
    /// Paints windowBackgroundColor where the panel material would be (labelled in index.html).
    let standIn: Bool
    /// Alignment rules checked against this scene's probes; [] = none.
    var rules: [AlignmentRule] = []
    let view: @MainActor () -> AnyView
    var appKit: (@MainActor () -> NSView)? = nil
}

/// Every scene, in index order. Each scene task appends its own array here.
@MainActor var allScenes: [GalleryScene] {
    componentScenes + queueScenes + stateScenes + detailScenes + settingsScenes + otherScenes
}
