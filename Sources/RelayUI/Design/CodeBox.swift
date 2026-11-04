import SwiftUI

extension View {
    /// The code fill behind a scrolling block of monospaced text (Show Difference's diff), with
    /// the code block's corner.
    public func codeBox() -> some View {
        background(DS.Color.codeFill, in: RoundedRectangle(cornerRadius: DS.Metric.codeRadius, style: .continuous))
    }
}
