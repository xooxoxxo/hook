import RelayCore
import SwiftUI

/// Design/FilterRow: the 32 pt row under the list header while a project filter
/// is on: the FilterToken on the left, the hidden-asks count on the right. Both clear the filter.
public struct FilterRow: View {
    let project: String
    let hidden: HiddenCount
    let onClear: () -> Void

    public init(project: String, hidden: HiddenCount, onClear: @escaping () -> Void) {
        self.project = project
        self.hidden = hidden
        self.onClear = onClear
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                FilterToken(project: project, onClear: onClear)
                Spacer(minLength: DS.Space.inline)
                if hidden.total > 0 { HiddenAsksButton(hidden: hidden, onClear: onClear) }
            }
            .padding(.horizontal, DS.Space.gutter)
            .frame(height: DS.Metric.filterRow)
            .background(DragHandle().accessibilityHidden(true))
            .background(DS.Color.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter")
            Divider()
        }
    }
}
