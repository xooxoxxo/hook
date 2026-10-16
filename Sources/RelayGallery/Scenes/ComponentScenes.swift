import RelayCore
import RelayUI
import SwiftUI

/// One captioned sample on the components sheet.
struct Sample {
    let caption: String
    let view: AnyView

    init<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) {
        self.caption = caption
        view = AnyView(content())
    }
}

struct SheetSection {
    let title: String
    let samples: [Sample]
}

/// The sheet's sections in reading order. Tasks 7–14 each append one.
@MainActor func sheetSections() -> [SheetSection] {
    [typeRamp(), controls()]
}

@MainActor func typeRamp() -> SheetSection {
    SheetSection(title: "Type ramp", samples: [
        Sample("DS.Font") {
            VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                Text("listTitle · headline").font(DS.Font.listTitle)
                Text("askTitle · title3 semibold").font(DS.Font.askTitle)
                Text("heading · headline").font(DS.Font.heading)
                Text("body · body").font(DS.Font.body)
                Text("currentAction · headline").font(DS.Font.currentAction)
                Text("meta · subheadline").font(DS.Font.meta)
                Text("prose · callout").font(DS.Font.prose)
                Text("code · callout monospaced").font(DS.Font.code)
                Text("caption · caption").font(DS.Font.caption)
                Text("welcomeTitle · title2 semibold").font(DS.Font.welcomeTitle)
            }
        },
    ])
}

@MainActor func controls() -> SheetSection {
    SheetSection(title: "Controls", samples: [
        Sample("IconButton · normal, tinted, disabled") {
            HStack(spacing: DS.Space.inline) {
                IconButton(DS.Symbol.refresh, label: "Refresh", help: "Refresh (⌘R)") {}
                IconButton(DS.Symbol.filterOn, label: "Group and filter", tint: DS.Color.accent) {}
                IconButton(DS.Symbol.next, label: "Next ask", help: "Next ask (⌘↓)") {}.disabled(true)
            }
        },
        Sample("HelpButton") { HStack { Text("Presence"); HelpButton(rowLabel: "Presence", text: "Relay marks you away when the screen locks.") } },
        Sample("TrailingDisclosureStyle · collapsed") {
            DisclosureGroup(isExpanded: .constant(false)) { Text("Hidden body") } label: { Text("Done step") }
                .disclosureGroupStyle(.trailing)
        },
        Sample("TrailingDisclosureStyle · expanded") {
            DisclosureGroup(isExpanded: .constant(true)) { Text("The body shows under the label.") } label: { Text("Done step") }
                .disclosureGroupStyle(.trailing)
        },
    ])
}

/// Three panel-wide columns; section i goes to column i % 3.
struct ComponentsSheet: View {
    let sections: [SheetSection]

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.section) {
            ForEach(0..<3, id: \.self) { column in
                VStack(alignment: .leading, spacing: DS.Space.section) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        if index % 3 == column { sectionView(section) }
                    }
                }
                .frame(width: DS.Metric.panelWidth, alignment: .topLeading)
            }
        }
        .padding(DS.Space.section)
    }

    private func sectionView(_ section: SheetSection) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.step) {
            Text(section.title).font(DS.Font.heading)
            ForEach(Array(section.samples.enumerated()), id: \.offset) { _, sample in
                VStack(alignment: .leading, spacing: DS.Space.rowLine) {
                    Text(sample.caption).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                    sample.view
                }
            }
        }
    }
}

@MainActor let componentScenes: [GalleryScene] = [
    GalleryScene(
        name: "components",
        size: .wide(width: 3 * DS.Metric.panelWidth + 4 * DS.Space.section, height: nil),
        standIn: true,
        view: { AnyView(ComponentsSheet(sections: sheetSections())) }),
]
