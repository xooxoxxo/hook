import AppKit
import RelayCore
import SwiftUI

/// Settings › Documents › Viewer: the viewer's look as one list (layout "Form list"):
/// the theme preset, a colour well per role, the reading width, a rendered sample, and
/// Reset to Theme. Kept in its own file so the rows can be rearranged. A change shows at
/// once; `ViewerThemeDraft` saves `viewer` in config.json a moment after the last one
/// (a colour well sends a change for every step of a drag).
public struct ViewerThemeSettings<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model
    @StateObject private var draft = ViewerThemeDraft()
    @Environment(\.colorScheme) private var scheme

    /// The roles with a well. The quote bar and rules colour is set in config.json only.
    static var roles: [ViewerTheme.Role] { [.background, .text, .headings, .links, .code] }

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    private var theme: ViewerTheme { draft.theme(saved: model.settings.config?.viewer) }

    private func set(_ next: ViewerTheme) {
        draft.change(to: next) { [model] in model.saveViewer($0) }
    }

    public var body: some View {
        Section("Viewer") {
            SettingsRow("Theme", help: DocumentsHelp.theme) {
                Picker("Theme", selection: Binding(
                    get: { theme.preset },
                    set: { preset in var next = theme; next.preset = preset; set(next) })) {
                    ForEach(ViewerTheme.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            ForEach(Self.roles, id: \.self) { role in
                SettingsRow(role.title, help: role == .background ? DocumentsHelp.colors : nil) {
                    ColorPicker(role.title, selection: binding(role), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            SettingsRow("Reading width", help: DocumentsHelp.width) {
                Picker("Reading width", selection: Binding(
                    get: { theme.width },
                    set: { width in var next = theme; next.width = width; set(next) })) {
                    ForEach(ViewerTheme.Width.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ViewerThemePreview(theme: theme)
            HStack {
                Spacer()
                Button("Reset to Theme") { set(theme.resettingColors) }
                    .disabled(theme.colors.isEmpty)
            }
        }
        .environment(\.settingsSection, "Viewer")
    }

    /// The appearance System colours resolve in for the wells: the theme's own, else Settings'.
    private var appearance: NSAppearance.Name {
        DS.Viewer.appearance(theme) ?? (scheme == .dark ? .darkAqua : .aqua)
    }

    /// The colour the role shows; a pick saves it as the owner's (unless it is the colour
    /// the role already has, which a well sends back when it opens).
    private func binding(_ role: ViewerTheme.Role) -> Binding<SwiftUI.Color> {
        Binding(
            get: {
                let hex = DS.Viewer.color(role, in: theme, appearance: appearance)
                return SwiftUI.Color(nsColor: DS.Viewer.nsColor(hex) ?? .labelColor)
            },
            set: { color in
                let hex = DS.Viewer.hex(NSColor(color))
                guard hex != DS.Viewer.color(role, in: theme, appearance: appearance) else { return }
                set(theme.setting(role, to: hex))
            })
    }
}

extension SettingsViewModel {
    /// Writes `viewer`, or removes it when the theme is the default look.
    func saveViewer(_ theme: ViewerTheme) {
        let value = theme.configValue
        if value.isEmpty { save(set: [:], remove: ["viewer"]) } else { save(set: ["viewer": value], remove: []) }
    }
}

/// The theme being edited: shown at once, saved after `DS.Viewer.saveDelay` without a change.
@MainActor final class ViewerThemeDraft: ObservableObject {
    @Published private(set) var pending: ViewerTheme?
    private var saving: Task<Void, Never>?

    /// The draft while one waits to be saved, else the saved theme.
    func theme(saved: ViewerTheme?) -> ViewerTheme { pending ?? saved ?? ViewerTheme() }

    func change(to theme: ViewerTheme, save: @escaping @MainActor (ViewerTheme) -> Void) {
        pending = theme
        saving?.cancel()
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(for: DS.Viewer.saveDelay)
            guard !Task.isCancelled, let self else { return }
            save(theme)
            self.pending = nil
        }
    }
}

extension ViewerTheme {
    /// The theme with every colour back to the preset's.
    var resettingColors: ViewerTheme {
        var next = self
        next.colors = [:]
        return next
    }
}
