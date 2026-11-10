import RelayCore
import SwiftUI

/// Settings → Documents: where a file row's Open goes, and how Hook's viewer looks (the
/// rows in `ViewerThemeSettings.swift`). Every control writes config.json through the model.
public struct DocumentsTab<Model: SettingsViewModel>: View {
    @ObservedObject private var model: Model

    public init(model: Model) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        Form {
            if model.settings.readOnly {
                ReadOnlySection { model.perform(.switchTab(.queue)) }
            }
            Section("Open") {
                SettingsRow("Open documents in", help: DocumentsHelp.openIn) {
                    Picker("Open documents in", selection: documentBinding) {
                        ForEach(documentOptions) { option in
                            if option.id == DocumentChoice.otherID { Divider() }
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            .environment(\.settingsSection, "Open")
            .disabled(model.settings.readOnly)
            ViewerThemeSettings(model: model)
                .disabled(model.settings.readOnly)
        }
        .formStyle(.grouped)
        .controlSize(DS.Control.form)
    }

    private var documentOptions: [DocumentChoice] {
        DocumentChoice.options(current: model.settings.config?.openDocumentsIn, appName: model.settings.documentAppName)
    }

    /// Saves the picked target; Other App… opens the app chooser instead (it saves on a pick).
    private var documentBinding: Binding<String> {
        Binding(
            get: { DocumentTarget(config: model.settings.config?.openDocumentsIn).configValue },
            set: { value in
                if value == DocumentChoice.otherID {
                    model.perform(.chooseDocumentApp)
                } else {
                    model.save(set: ["openDocumentsIn": value], remove: [])
                }
            })
    }
}

/// The Documents tab's "?" texts.
public enum DocumentsHelp {
    public static let openIn = "What Open does on a document an ask links to. Hook's viewer shows Markdown (.md, .markdown) rendered and text (.txt) as it is, in its own window, without going online; other files open in their default app. The file's default app and a chosen app open every file. Each file row's ⋯ menu also has Open With, Reveal in Finder and Copy Path. Hook reads a file only when you press Open."
    public static let theme = "The palette the viewer starts from. System uses the Mac's own colours and follows light and dark. Paper, Sepia and Night keep their colours whatever the appearance, and the viewer's title bar goes light or dark to match. Open viewer windows change at once."
    public static let colors = "Click a colour well to use your own colour for that part of the page, over the theme's. A colour you pick applies in light and dark. Reset to Theme goes back to the theme's colours."
    public static let width = "How wide the text may grow. Full fills the window, less a margin. Wide and Narrow stop at a comfortable line length and centre the text; a wider window adds margins. Tables use the same width and scroll sideways only when they can't fit."
}
