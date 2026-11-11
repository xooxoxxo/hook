import RelayUIMac
import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// The profile switcher's menu, open above the status bar. macOS draws the real menu in
/// its own window, which can't be captured offscreen, so this is a stand-in: the same
/// items and strings as `StatusBar`'s menu, in the system menu font, on the menu's
/// colours. It checks that the names and the switcher's label fit, not the menu's chrome.
struct ProfileMenuStandIn: View {
    let profiles: ProfileMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profiles.profiles) { profile in
                item(line(profile.name), checked: profile.current)
            }
            Divider().padding(.vertical, 5).padding(.horizontal, 10)
            item(StatusBarText.queueSettings, checked: false)
            if !profiles.pondSaved { item(StatusBarText.setUpPond, checked: false) }
        }
        .padding(.vertical, 5)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    private func item(_ title: String, checked: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0)
            Text(title).lineLimit(1)
        }
        .font(Font(NSFont.menuFont(ofSize: 0)))
        .padding(.leading, 10).padding(.trailing, 24)
        .frame(height: 22)
    }
}

/// The plain queue with the switcher's menu open over its bottom, as it sits when clicked.
@MainActor func profileMenuScene(_ name: String, _ profiles: ProfileMenu, status: PanelStatus = readyStatus) -> GalleryScene {
    let model = queueModel(GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
                           status: status, profiles: profiles)
    let overrides = PanelGalleryOverrides(now: GalleryFixtures.now)
    return GalleryScene(
        name: name, size: .panel(height: queueHeight), standIn: true, rules: queueEdgeRules,
        view: {
            AnyView(PanelRoot(model: model).environment(\.panelGallery, overrides)
                .overlay(alignment: .bottomLeading) {
                    ProfileMenuStandIn(profiles: profiles)
                        .padding(.leading, DS.Space.gutter - 10)
                        .padding(.bottom, DS.Metric.statusBar - 4)
                })
        },
        appKit: nil)
}

/// A Pond with a long context: the switcher's label must leave the status word and Settings room.
let longPondProfiles = ProfileMenu(
    profiles: [Profile(kind: .local, name: ProfileMenu.thisMac, current: false),
               Profile(kind: .mailbox, name: ProfileMenu.name(context: "atlas-warehouse-migration-and-quarterly-capacity-review-team"), current: true)],
    readOnly: false, pondSaved: true)

@MainActor var profileMenuScenes: [GalleryScene] {
    [
        profileMenuScene("queue-profile-menu", FixturePanelModel.pondProfiles),
        profileMenuScene("queue-profile-menu-local", FixturePanelModel.localProfiles,
                         status: PanelStatus.make(StatusInputs(sourceKey: SourceKey.local, reachable: true, loadedOnce: true))),
        statusScene("queue-status-long-profile", offlineStatus(loadedOnce: true), profiles: longPondProfiles),
    ]
}
