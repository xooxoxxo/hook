import RelayCore
import SwiftUI

/// Design/CrashBar: the last run crashed. A warning symbol, "Hook quit unexpectedly" with
/// what is ready ("Last run · report ready, nothing sent"), then Not Now (borderless) and
/// Review… (prominent, opens the send sheet). It docks above the status bar, and above the
/// detail's bottom bars, the way the Undo bar does, and stays until it is answered.
public struct CrashBar: View {
    let offer: CrashOffer
    let onNotNow: () -> Void
    let onReview: () -> Void

    public init(offer: CrashOffer, onNotNow: @escaping () -> Void, onReview: @escaping () -> Void) {
        self.offer = offer
        self.onNotNow = onNotNow
        self.onReview = onReview
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: DS.Space.inline) {
                HStack(spacing: DS.Space.inline) {
                    Image(systemName: DS.Symbol.warning).foregroundStyle(DS.Color.warn)
                    VStack(alignment: .leading, spacing: DS.Space.barCaption) {
                        Text(Self.title).font(DS.Font.prose)
                        Text(Self.caption(offer)).font(DS.Font.caption).foregroundStyle(DS.Color.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityText(offer))
                Spacer(minLength: 0)
                Button(Self.notNow, action: onNotNow)
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.Color.secondary)
                    .help(Self.notNowHelp)
                Button(Self.review, action: onReview)
                    .buttonStyle(.borderedProminent)
                    .help(Self.reviewHelp)
            }
            .controlSize(DS.Control.form)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.barStackV)
            .background(DS.Color.bar)
        }
    }

    public static let title = "Hook quit unexpectedly"
    public static let notNow = "Not Now"
    public static let review = "Review…"
    public static let notNowHelp = "Don't report this crash. Hook won't ask about it again."
    public static let reviewHelp = "See exactly what would be sent before anything leaves this Mac"

    /// "Last run · report ready, nothing sent", or "… no crash report, log only" after a
    /// hang, a force quit or a kill.
    public static func caption(_ offer: CrashOffer) -> String {
        "Last run · " + (offer.summary.report == nil ? "no crash report, log only" : "report ready, nothing sent")
    }

    public static func accessibilityText(_ offer: CrashOffer) -> String { title + ". " + caption(offer) }
}
