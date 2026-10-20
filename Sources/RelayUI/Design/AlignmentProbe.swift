import SwiftUI

/// What a probe marks, for the gallery's alignment check.
public enum ProbeRole: String, Sendable, CaseIterable {
    case gutterText, trailingEdge, cardText, cardTrailing, cardEdge, topMarker, subMarker, topActionText, subLabelText, settingsTrailing, mailboxField
}

/// How the alignment check measures a probe. `.ink` scans the pixels inside the probe's frame;
/// `.frame` takes the frame's own edges, for text that can begin or end with a digit (a tabular
/// digit's side bearings sit 1.5–2.5 pt inside its advance) and for bordered controls whose bezel
/// is too faint for the scan.
public enum ProbeMeasure: Sendable {
    case ink, frame
}

/// A probed view's frame in the window frame view's space (`.global`), in points, top-left origin,
/// title bar included. In a borderless window that is the content view's space.
public struct ProbeFrame: Equatable, Sendable {
    public var role: ProbeRole
    /// Groups probes that must agree among themselves (one Settings section).
    public var group: String
    public var frame: CGRect
    public var measure: ProbeMeasure

    public init(role: ProbeRole, group: String, frame: CGRect, measure: ProbeMeasure = .ink) {
        self.role = role
        self.group = group
        self.frame = frame
        self.measure = measure
    }
}

public struct AlignmentProbeKey: PreferenceKey {
    public static let defaultValue: [ProbeFrame] = []
    public static func reduce(value: inout [ProbeFrame], nextValue: () -> [ProbeFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// Collects probe frames from inside List rows, where preferences don't reach the root.
@MainActor public final class AlignmentProbeSink {
    private var latest: [UUID: ProbeFrame] = [:]
    private var order: [UUID] = []

    public init() {}

    public func record(_ id: UUID, _ frame: ProbeFrame) {
        if latest[id] == nil { order.append(id) }
        latest[id] = frame
    }

    public var frames: [ProbeFrame] { order.compactMap { latest[$0] } }
}

private struct AlignmentProbesEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AlignmentProbeSinkKey: EnvironmentKey {
    static let defaultValue: AlignmentProbeSink? = nil
}

extension EnvironmentValues {
    /// Off everywhere except in RelayGallery.
    public var alignmentProbesEnabled: Bool {
        get { self[AlignmentProbesEnabledKey.self] }
        set { self[AlignmentProbesEnabledKey.self] = newValue }
    }

    public var alignmentProbeSink: AlignmentProbeSink? {
        get { self[AlignmentProbeSinkKey.self] }
        set { self[AlignmentProbeSinkKey.self] = newValue }
    }
}

private struct AlignmentProbeModifier: ViewModifier {
    let role: ProbeRole
    let group: String
    let measure: ProbeMeasure
    @Environment(\.alignmentProbesEnabled) private var enabled
    @Environment(\.alignmentProbeSink) private var sink
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if enabled {
            content.background(GeometryReader { proxy in
                let frame = ProbeFrame(role: role, group: group, frame: proxy.frame(in: .global), measure: measure)
                Color.clear
                    .preference(key: AlignmentProbeKey.self, value: [frame])
                    .onAppear { sink?.record(id, frame) }
                    .onChange(of: frame) { _, new in sink?.record(id, new) }
            })
        } else {
            content
        }
    }
}

extension View {
    /// Marks this view for the gallery's alignment check; does nothing in the app.
    /// `measure: .frame` checks the view's frame instead of its ink (see `ProbeMeasure`).
    public func alignmentProbe(_ role: ProbeRole, group: String = "", measure: ProbeMeasure = .ink) -> some View {
        modifier(AlignmentProbeModifier(role: role, group: group, measure: measure))
    }
}
