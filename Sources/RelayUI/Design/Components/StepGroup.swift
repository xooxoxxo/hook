import SwiftUI

/// Design/StepGroup: the detail's inset grouped list, System Settings style. Rows sit on one
/// rounded fill, with `GroupDivider` hairlines between them inset to the text column.
public struct StepGroup<Content: View>: View {
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Metric.groupRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(DS.Color.groupFill))
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(DS.Color.cardStrokeContrast, lineWidth: DS.Metric.cardBorderContrast)
                } else {
                    shape.strokeBorder(DS.Color.groupStroke, lineWidth: DS.Metric.cardBorder)
                }
            }
    }
}

/// The hairline between two rows of a `StepGroup`, starting at the text column.
public struct GroupDivider: View {
    public init() {}

    public var body: some View {
        Divider().padding(.leading, DS.Space.groupText)
    }
}
