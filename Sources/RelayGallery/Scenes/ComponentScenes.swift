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
    [typeRamp(), controls(), rows(), headers()]
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

/// A one-off sidebar List, so rows render with real List chrome.
struct MiniList<Content: View>: View {
    let height: CGFloat
    var selection: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        List(selection: .constant(selection)) { content }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, DS.Metric.rowMinHeight)
            .frame(height: height)
    }
}

let rowInsets = EdgeInsets(top: DS.Space.rowInsetV, leading: DS.Space.rowInsetH,
                           bottom: DS.Space.rowInsetV, trailing: DS.Space.rowInsetH)

let sampleRows: [AskRowModel] = [
    AskRowModel(id: "r1", title: "Renew the staging certificate and the deploy key", project: "Acme", urgency: .now,
                created: "2026-10-16T06:40:00Z", summary: .steps(done: 2, total: 8)),
    AskRowModel(id: "r2", title: "Choose the backup region", project: "Acme", urgency: .today,
                created: "2026-10-16T00:40:00Z", summary: .steps(done: 0, total: 1)),
    AskRowModel(id: "r3", title: "Review the onboarding checklist", project: "Acme", urgency: .today,
                created: "2026-10-15T23:40:00Z", summary: .steps(done: 0, total: 4), hasDraft: true),
    AskRowModel(id: "r4", title: "Send the release notes draft", project: "Relay", urgency: .whenever,
                created: "2026-10-15T09:40:00Z", summary: .steps(done: 0, total: 2)),
    AskRowModel(id: "r5", title: "Pick a colour for the dashboard theme", project: "Northwind", urgency: .today,
                created: "2026-10-16T04:40:00Z", summary: .choose(3)),
    AskRowModel(id: "r6", title: "Send the invoice number from the receipt", project: "Atlas", urgency: .unknown("soon"),
                created: "2026-10-15T09:40:00Z", summary: .reply),
]

let sampleClosed = AskRowModel(id: "c1", title: "Store the API key", project: "Acme", urgency: .today,
                               created: "2026-10-16T05:40:00Z", summary: .none,
                               closed: ClosedInfo(status: "done", closedBy: "owner", completedAt: "2026-10-16T06:40:00Z"))

@MainActor func rows() -> SheetSection {
    func askRow(_ row: AskRowModel, _ grouping: QueueGrouping, age: String, selected: String? = nil) -> some View {
        MiniList(height: 64, selection: selected) {
            AskRow(row: row, age: age, grouping: grouping, selected: row.id == selected, onShowOnlyProject: {})
                .listRowInsets(rowInsets).tag(row.id)
        }
    }
    return SheetSection(title: "Rows", samples: [
        Sample("UrgencyLabel · now, today, whenever, unknown") {
            HStack(spacing: DS.Space.section) {
                UrgencyLabel(.now); UrgencyLabel(.today); UrgencyLabel(.whenever); UrgencyLabel(.unknown("soon"))
            }
            .font(DS.Font.meta)
        },
        Sample("SectionHeader · urgency and project, empty name") {
            MiniList(height: 120) {
                Section { EmptyView() } header: { SectionHeader(name: "Now", count: 1) }
                Section { EmptyView() } header: { SectionHeader(name: "Acme", count: 3) }
                Section { EmptyView() } header: { SectionHeader(name: "", count: 1) }
            }
        },
        Sample("AskRow · Project grouping, now with progress") { askRow(sampleRows[0], .project, age: "3 h ago") },
        Sample("AskRow · Project grouping, today") { askRow(sampleRows[1], .project, age: "9 h ago") },
        Sample("AskRow · Project grouping, whenever") { askRow(sampleRows[3], .project, age: "1 d ago") },
        Sample("AskRow · Urgency grouping, project on line 2") { askRow(sampleRows[0], .urgency, age: "3 h ago") },
        Sample("AskRow · selected") { askRow(sampleRows[1], .project, age: "9 h ago", selected: "r2") },
        Sample("AskRow · draft pending") { askRow(sampleRows[2], .project, age: "10 h ago") },
        Sample("AskRow · choice summary") { askRow(sampleRows[4], .project, age: "5 h ago") },
        Sample("AskRow · reply summary, unknown urgency") { askRow(sampleRows[5], .project, age: "1 d ago") },
        Sample("ClosedAskRow") {
            MiniList(height: 64) { ClosedAskRow(row: sampleClosed, closedLine: "Done 3 h ago", onReopen: {}, onShowOnlyProject: {}).listRowInsets(rowInsets) }
        },
        Sample("ClosedGroupHeader · collapsed, expanded") {
            MiniList(height: 72) {
                Section { EmptyView() } header: { ClosedGroupHeader(count: 2, expanded: .constant(false)) }
                Section { EmptyView() } header: { ClosedGroupHeader(count: 2, expanded: .constant(true)) }
            }
        },
        Sample("EmptyListLine · plain, filtered") {
            MiniList(height: 190) {
                EmptyListLine(project: nil, onShowAll: {})
                EmptyListLine(project: "Acme", onShowAll: {})
            }
        },
    ])
}

let sampleProjects = [MenuProject(name: "Acme", open: 3), MenuProject(name: "Northwind", open: 1), MenuProject(name: "Relay", open: 1)]
let longProject = "Quarterly planning for the public launch of the pricing page"

@MainActor func headers() -> SheetSection {
    func list(_ title: String, refreshing: Bool = false, filter: String? = nil, hidden: HiddenCount = .zero) -> some View {
        ListHeaderBar(title: title, refreshing: refreshing, updated: "09:40", grouping: .constant(.project),
                      filter: .constant(filter), projects: sampleProjects, hidden: hidden,
                      onRefresh: {}, onHide: {}, onDock: { _ in })
    }
    func detail(previous: Neighbour, next: Neighbour) -> some View {
        DetailHeaderBar(project: "Acme", urgency: .now, age: "3 h ago", previous: previous, next: next,
                        onBack: {}, onPrevious: {}, onNext: {}, onHide: {}, onDock: { _ in })
    }
    return SheetSection(title: "Headers", samples: [
        Sample("ListHeaderBar · idle") { list("5 waiting") },
        Sample("ListHeaderBar · manual refresh running") { list("5 waiting", refreshing: true) },
        Sample("ListHeaderBar · filtered, 2 hidden") { list("3 waiting", filter: "Acme", hidden: HiddenCount(total: 2, now: 0)) },
        Sample("ListHeaderBar · filtered, hidden now") { list("1 waiting", filter: "Relay", hidden: HiddenCount(total: 4, now: 1)) },
        Sample("FilterRow · long name") { FilterRow(project: longProject, hidden: HiddenCount(total: 4, now: 0), onClear: {}) },
        Sample("DetailHeaderBar · middle") { detail(previous: .ask("p"), next: .ask("n")) },
        Sample("DetailHeaderBar · at the end") { detail(previous: .ask("p"), next: .end) },
        Sample("DetailHeaderBar · outside the filter") { detail(previous: .outsideFilter, next: .outsideFilter) },
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
