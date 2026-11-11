import RelayUI
import RelayCore
import SwiftUI

/// Design/StatusBar: the profile switcher on the left, then the status word in its tone's
/// colour (it opens a details popover), and Settings on the right. Quiet when all is fine:
/// the Pond reads "Pond" in green, This Mac shows no word at all. The one place a
/// persistent problem shows in the panel.
public struct StatusBar<Details: View>: View {
    let status: PanelStatus
    let profiles: ProfileMenu
    let onSwitch: (SourceKind) -> Void
    let onQueueSettings: () -> Void
    let onSettings: () -> Void
    /// Set for the one state whose click opens setup instead of the popover.
    let onActivate: (() -> Void)?
    let details: () -> Details
    @State private var showDetails = false

    public init(status: PanelStatus, profiles: ProfileMenu, onSwitch: @escaping (SourceKind) -> Void,
                onQueueSettings: @escaping () -> Void, onSettings: @escaping () -> Void,
                onActivate: (() -> Void)? = nil, @ViewBuilder details: @escaping () -> Details) {
        self.status = status
        self.profiles = profiles
        self.onSwitch = onSwitch
        self.onQueueSettings = onQueueSettings
        self.onSettings = onSettings
        self.onActivate = onActivate
        self.details = details
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: DS.Space.inline) {
                profileMenu
                if !status.text.isEmpty {
                    Button {
                        if let onActivate { onActivate() } else { showDetails = true }
                    } label: {
                        Text(status.text)
                            .foregroundStyle(Self.color(status.tone))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(StatusBarText.accessibilityText(status))
                    .popover(isPresented: $showDetails, arrowEdge: .top) {
                        details()
                            .padding(DS.Space.popover)
                            .frame(width: DS.Metric.helpWidth)
                    }
                }
                Spacer(minLength: 0)
                IconButton(DS.Symbol.settings, label: "Settings", help: "Settings (⌘,)", action: onSettings)
            }
            .font(DS.Font.meta)
            .padding(.horizontal, DS.Space.gutter)
            .frame(height: DS.Metric.statusBar)
            .background(DS.Color.bar)
        }
    }

    /// A stock borderless menu: the profiles (checked on the shown one), then Queue
    /// Settings… and, without a saved Pond, Set Up a Pond….
    private var profileMenu: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Toggle(isOn: Binding(get: { profile.current }, set: { on in if on { onSwitch(profile.kind) } })) {
                    Text(line(profile.name))
                }
            }
            Divider()
            Button(StatusBarText.queueSettings, action: onQueueSettings)
            if !profiles.pondSaved {
                Button(StatusBarText.setUpPond, action: onQueueSettings)
            }
        } label: {
            Text(line(profiles.shortLabel)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        // A stock menu draws its label at the control's size: small matches the bar's text.
        .controlSize(DS.Control.inline)
        .fixedSize()
        .disabled(profiles.readOnly)
        .help(profiles.readOnly ? ProfileMenu.readOnlyHelp : StatusBarText.profileHelp)
        .accessibilityLabel(StatusBarText.profileLabel(profiles.label))
    }

    /// Green when fine, orange for a problem, secondary otherwise: the text tints that
    /// reach 4.5:1 in both themes.
    static func color(_ tone: StatusTone) -> Color {
        switch tone {
        case .ok: DS.Color.doneText
        case .warn: DS.Color.warnText
        case .neutral: DS.Color.secondary
        }
    }
}

/// StatusBar's strings. A non-generic namespace, since `StatusBar` is generic.
public enum StatusBarText {
    public static let queueSettings = "Queue Settings…"
    public static let setUpPond = "Set Up a Pond…"
    public static let profileHelp = "Switch between This Mac and your Pond"

    /// "Status: Pond, ready. Shows details".
    public static func accessibilityText(_ status: PanelStatus) -> String { "Status: \(status.spoken). Shows details" }

    /// "Profile Personal".
    public static func profileLabel(_ name: String) -> String { "Profile \(line(name))" }
}
