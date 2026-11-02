import RelayCore
import SwiftUI

/// The inline review (Show Changes): inside the ask, in place of its body. Who changed it and
/// why, then every step of the version under review with a unified diff under each one that
/// changed and its Look-closer flags right below, then what else changed and what resets.
/// Nothing in it can be selected, copied or opened; the bar (`DetailReviewBar`) accepts.
struct DetailReview: View {
    let page: ReviewPage?

    var body: some View {
        if let page {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                header(page)
                if !page.reasons.isEmpty { reasons(page) }
                steps(page)
                if !page.others.isEmpty { section("Also changed", rows: page.others) }
                if !page.resets.isEmpty { resets(page) }
            }
            .textSelection(.disabled)
        } else {
            ProgressView { Text("Loading the changes…") }
                .controlSize(DS.Control.inline)
                .accessibilityLabel("Loading the changes")
        }
    }

    private func header(_ page: ReviewPage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                Text(verbatim: page.heading)
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                Spacer(minLength: 0)
                HelpButton(rowLabel: "Edit key", text: ReviewPage.editKeyHelp)
            }
            Text(verbatim: page.since)
                .font(DS.Font.prose)
                .foregroundStyle(DS.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: page.attribution)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every reason since the baseline, oldest first, each in a bordered quote.
    private func reasons(_ page: ReviewPage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            ForEach(page.reasons, id: \.rev) { reason in
                ReasonQuote(reason)
            }
        }
    }

    private func steps(_ page: ReviewPage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            HStack(alignment: .firstTextBaseline) {
                Text("Steps")
                    .font(DS.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                Spacer()
                Text(verbatim: page.stepsSummary).font(DS.Font.meta).foregroundStyle(DS.Color.secondary)
            }
            group(page.steps)
        }
    }

    private func section(_ title: String, rows: [ReviewPage.Row]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            Text(title)
                .font(DS.Font.heading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)
            group(rows)
        }
    }

    private func group(_ rows: [ReviewPage.Row]) -> some View {
        StepGroup {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { GroupDivider() }
                ReviewRow(row: row)
            }
        }
    }

    private func resets(_ page: ReviewPage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            Text("What resets")
                .font(DS.Font.heading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)
            StepGroup {
                ForEach(Array(page.resets.enumerated()), id: \.offset) { index, text in
                    if index > 0 { GroupDivider() }
                    Label(text, systemImage: "arrow.uturn.backward")
                        .font(DS.Font.prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.groupRowH)
                        .padding(.vertical, DS.Space.groupRowV)
                }
            }
        }
    }
}

/// The review's sticky bar: the flag count (or the newer version's line), Skip (always
/// allowed), Not Now, and Use Version N (Touch ID when a command, link or file changed), off
/// while an accept is in flight. Once a newer version arrived the primary shows it instead, and
/// never accepts the one on screen.
struct DetailReviewBar<Model: PanelViewModel>: View {
    @ObservedObject var model: Model
    let id: String
    let page: ReviewPage?

    /// The bar's buttons, left to right.
    static func buttonTitles(page: ReviewPage?) -> [String] {
        ["Skip", ReviewPage.notNow] + (page.map { [$0.primaryTitle] } ?? [])
    }

    /// The primary is off until the page is there, and while an accept is in flight.
    static func primaryEnabled(page: ReviewPage?, accepting: Bool) -> Bool { page != nil && !accepting }

    var body: some View {
        ReviewBar(tone: .correction, title: page?.barTitle ?? "Loading the changes",
                  detail: page?.barDetail ?? LookCloser.incomplete, help: ReviewPage.lookCloserHelp) {
            Button("Skip") { model.close(id, .declined) }
                .help(ActionBar.skipHelp)
                .keyboardShortcut(KeyboardShortcut(.delete, modifiers: .command))
            Button(ReviewPage.notNow) { model.endReview(id) }
            Spacer(minLength: DS.Space.inline)
            if let page {
                Button {
                    if page.isStale { model.startReview(id) } else { model.accept(id, stamp: page.target) }
                } label: {
                    if page.needsPresence, !page.isStale {
                        Label(page.primaryTitle, systemImage: DS.Symbol.presence)
                    } else {
                        Text(verbatim: page.primaryTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!Self.primaryEnabled(page: page, accepting: model.isAccepting(id)))
                .help(page.needsPresence && !page.isStale ? ReviewPage.presenceNote : page.primaryTitle)
            }
        }
    }
}

/// The locked ask's bar, in place of the action bar: why it is locked, Skip (always allowed),
/// and Show Changes, or Trust the Pond's History Again… after a history check failed.
struct DetailLockBar<Model: PanelViewModel>: View {
    @ObservedObject var model: Model
    let id: String
    let bar: ReviewLockBar

    var body: some View {
        ReviewBar(tone: bar.tone == .history ? .history : .correction, title: bar.title, detail: bar.detail,
                  help: bar.tone == .history ? ReviewLockBar.historyHelp : ReviewLockBar.lockHelp) {
            Button("Skip") { model.close(id, .declined) }
                .help(ActionBar.skipHelp)
                .keyboardShortcut(KeyboardShortcut(.delete, modifiers: .command))
            Spacer(minLength: DS.Space.inline)
            Button(bar.action) {
                if bar.tone == .history { model.trustHistoryAgain() } else { model.startReview(id) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
