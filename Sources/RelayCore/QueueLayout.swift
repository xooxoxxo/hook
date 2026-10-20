import Foundation

public struct QueueSection: Equatable, Sendable, Identifiable {
    public enum Header: Equatable, Sendable {
        case urgency(Urgency)
        /// The raw project string; "" is "No project" on screen.
        case project(String)
    }

    /// nil: the rows render flat, without a section header.
    public var header: Header?
    public var items: [WireItem]
    public var id: String

    public init(header: Header?, items: [WireItem]) {
        self.header = header
        self.items = items
        switch header {
        case .urgency(let urgency)?: id = "urgency." + urgency.word.lowercased()
        case .project(let project)?: id = "project." + project
        case nil: id = "flat"
        }
    }
}

/// How the open queue is sectioned and ordered.
public enum QueueLayout {
    public static func sections(items: [WireItem], grouping: QueueGrouping, filter: String?) -> [QueueSection] {
        let shown = items.filter { matches($0, filter: filter) }
        guard !shown.isEmpty else { return [] }
        switch grouping {
        case .urgency:
            return [Urgency.now, .today, .whenever].compactMap { urgency in
                let members = shown.filter { bucket($0) == urgency }
                return members.isEmpty ? nil : QueueSection(header: .urgency(urgency), items: members)
            }
        case .project:
            var order: [String] = []
            var groups: [String: [WireItem]] = [:]
            for item in shown {
                let project = item.projectId ?? ""
                if groups[project] == nil { order.append(project) }
                groups[project, default: []].append(item)
            }
            if filter != nil || order.count == 1 {
                return [QueueSection(header: nil, items: rowOrder(shown))]
            }
            let sorted = order.sorted { a, b in
                let ga = groups[a]!, gb = groups[b]!
                let nowA = ga.contains { bucket($0) == .now }, nowB = gb.contains { bucket($0) == .now }
                if nowA != nowB { return nowA }
                let newestA = ga.map(createdDate).max()!, newestB = gb.map(createdDate).max()!
                if newestA != newestB { return newestA > newestB }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            return sorted.map { QueueSection(header: .project($0), items: rowOrder(groups[$0]!)) }
        }
    }

    public static func visibleOrder(_ sections: [QueueSection]) -> [String] {
        sections.flatMap { $0.items.map(\.id) }
    }

    /// The filter compares the raw project string, never the sanitized one.
    public static func matches(_ item: WireItem, filter: String?) -> Bool {
        guard let filter else { return true }
        return (item.projectId ?? "") == filter
    }

    /// Urgency rank (unknown counts as today), then created newest first; ties keep source order.
    static func rowOrder(_ items: [WireItem]) -> [WireItem] {
        items.enumerated().sorted { a, b in
            let ra = Urgency(raw: a.element.urgency).rank, rb = Urgency(raw: b.element.urgency).rank
            if ra != rb { return ra < rb }
            let da = createdDate(a.element), db = createdDate(b.element)
            if da != db { return da > db }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The Urgency section an ask goes in; unknown urgencies go in Today.
    static func bucket(_ item: WireItem) -> Urgency {
        let urgency = Urgency(raw: item.urgency)
        if case .unknown = urgency { return .today }
        return urgency
    }

    static func createdDate(_ item: WireItem) -> Date {
        Timestamp.date(item.created) ?? .distantPast
    }
}

extension QueueLayout {
    /// Open asks outside the filter, and how many of them are "now".
    public static func hiddenCount(items: [WireItem], filter: String?) -> HiddenCount {
        guard filter != nil else { return .zero }
        let hidden = items.filter { !matches($0, filter: filter) }
        return HiddenCount(total: hidden.count, now: hidden.filter { bucket($0) == .now }.count)
    }

    /// Every project with an open ask, by name; the filtered project always appears.
    public static func menuProjects(items: [WireItem], filter: String?) -> [MenuProject] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.projectId ?? "", default: 0] += 1 }
        if let filter, counts[filter] == nil { counts[filter] = 0 }
        return counts.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { MenuProject(name: $0, open: counts[$0]!) }
    }

    /// Recently closed, inside the filter.
    public static func closed(_ items: [WireItem], filter: String?) -> [WireItem] {
        items.filter { matches($0, filter: filter) }
    }

    /// Leaves without building nodes: a step's sub-steps (at most ten) or the step; then verify.
    public static func leafCount(_ instructable: Instructable) -> Int {
        let steps = instructable.steps.reduce(0) { sum, step in
            sum + min(max(step.substeps?.count ?? 0, 1), StepLevel.letters.count)
        }
        return steps + (instructable.verify == nil ? 0 : 1)
    }

    public static func summary(for item: WireItem, ticked: Set<String>) -> RowSummary {
        guard let ins = item.instructable else {
            if present(item.payload.cmd) { return .legacyCmd }
            if present(item.payload.link) { return .legacyLink }
            return .none
        }
        if !ins.steps.isEmpty {
            let total = leafCount(ins)
            return .steps(done: min(ticked.count, total), total: total)
        }
        if let choices = ins.reply?.choices, !choices.isEmpty { return .choose(choices.count) }
        return ins.reply == nil ? .none : .reply
    }

    private static func present(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
