import RelayCore
import SwiftUI

/// Required before Done (Pond 1.3.0, owner pick 1): what's left is marked by sight, never by a
/// label. A required step or sub-step not finished yet carries `RequiredBadge` on its marker
/// and the `requiredRow` hue behind its row; the Messages section and the reply prompt carry
/// the badge after their heading and the hue behind the section. Each mark goes the moment its
/// item is finished, and the row then reads like any finished one. VoiceOver hears ", required"
/// on the label instead (`StepAccessibility.required`), so the badge itself is hidden from it.
public enum RequiredMark {
    /// The step and sub-step paths whose rows carry the mark: the required ones left.
    public static func stepPaths(_ requirements: RequirementState) -> Set<String> {
        Set(requirements.left.compactMap { item in
            if case .step(let path, _) = item { return path }
            return nil
        })
    }

    /// A marked heading's VoiceOver value; nil when it isn't marked.
    public static func headingValue(_ marked: Bool) -> String? { marked ? "required" : nil }
}

/// Design/RequiredBadge: a small accent dot. On a step it sits on the marker's top-trailing
/// edge, inside the marker's own column, so it never moves the text.
public struct RequiredBadge: View {
    public init() {}

    public var body: some View {
        Image(systemName: DS.Symbol.requiredBadge)
            .resizable()
            .frame(width: DS.Metric.requiredBadge, height: DS.Metric.requiredBadge)
            .foregroundStyle(DS.Color.required)
            .accessibilityHidden(true)
            .alignmentProbe(.requiredBadge, measure: .frame)
    }
}

/// The required hue: the accent at a low opacity, inset in its row like the report target's
/// outline, so it stays inside the grouped list's rounded shape.
/// Under Increase Contrast the hue is stronger; the badge keeps the meaning on its own.
struct RequiredRowHue: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Metric.groupRadius - DS.Metric.targetInset, style: .continuous)
            .fill(contrast == .increased ? DS.Color.requiredRowContrast : DS.Color.requiredRow)
            .padding(DS.Metric.targetInset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The badge on a step marker's top-trailing edge while `on`.
    func requiredBadge(_ on: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if on { RequiredBadge() }
        }
    }

    /// The required hue behind this row while `on`, reaching `bleed` past its edges (a sub-step
    /// row, or a parent's header, whose padding sits outside it); the row keeps its layout.
    func requiredRow(_ on: Bool, bleed: EdgeInsets = EdgeInsets()) -> some View {
        background {
            if on {
                RequiredRowHue()
                    .padding(.top, -bleed.top)
                    .padding(.leading, -bleed.leading)
                    .padding(.bottom, -bleed.bottom)
                    .padding(.trailing, -bleed.trailing)
            }
        }
    }
}

/// Whether this step row carries the required mark: DetailSteps sets it per node, and a
/// parent per sub-step from `requiredSteps`.
private struct StepRequiredKey: EnvironmentKey {
    static let defaultValue = false
}

/// The marked step paths (`RequiredMark.stepPaths`), for a parent to mark its sub-steps.
private struct RequiredStepsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    public var stepRequired: Bool {
        get { self[StepRequiredKey.self] }
        set { self[StepRequiredKey.self] = newValue }
    }

    public var requiredSteps: Set<String> {
        get { self[RequiredStepsKey.self] }
        set { self[RequiredStepsKey.self] = newValue }
    }
}

/// A section heading's badge, after its "?" (Messages, Reply), while `on`: in a row aligned on
/// the heading's first baseline, its centre sits at the middle of the heading's capitals.
struct RequiredHeadingBadge: View {
    let on: Bool

    var body: some View {
        if on {
            RequiredBadge()
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + DS.Font.headingCapHeight / 2 }
        }
    }
}

extension View {
    /// The required hue behind a whole section (Messages, the reply) while `on`, reaching
    /// `DS.Space.requiredBleed` past it on every side, so its text keeps the gutter.
    func requiredSection(_ on: Bool) -> some View {
        let bleed = DS.Space.requiredBleed
        return requiredRow(on, bleed: EdgeInsets(top: bleed, leading: bleed, bottom: bleed, trailing: bleed))
    }
}
