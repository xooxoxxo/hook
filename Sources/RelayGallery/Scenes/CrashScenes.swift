import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// What a report of the gallery crash says, built by the same text the app sends.
@MainActor func galleryReport(_ summary: CrashSummary, source: String = "Pond", pond: String? = "1.2.0") -> String {
    CrashReportText.body(summary, source: source, pond: pond, log: GalleryFixtures.crashLog,
                         home: "/Users/me", user: "me")
}

/// The send sheet on its own, panel wide, as macOS shows it attached to the panel.
@MainActor func crashSheetScene(_ name: String, _ sheet: CrashSheetModel) -> GalleryScene {
    let model = FixturePanelModel(queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
                                  status: readyStatus, crashOffer: CrashOffer(summary: sheet.summary))
    model.crashSheet = sheet
    let overrides = PanelGalleryOverrides(now: GalleryFixtures.now, locale: galleryGB, timeZone: galleryUTC)
    return GalleryScene(name: name, size: .wide(width: DS.Metric.panelWidth, height: nil), standIn: false,
                        view: { AnyView(CrashReportSheet(model: model).environment(\.panelGallery, overrides)
                            .background(DS.Color.panelStandInOpaque)) })
}

@MainActor var crashScenes: [GalleryScene] {
    var withFile = GalleryFixtures.crash
    withFile.reportFile = URL(fileURLWithPath: "/Users/me/Library/Logs/DiagnosticReports/Hook-2026-10-15-221410.ips")
    var failed = CrashSheetModel(summary: withFile, target: .pond, pondOffered: true, preview: galleryReport(withFile))
    failed.send = .failed("The Pond didn't answer within 10 seconds.")
    return [
        crashSheetScene("crash-sheet-pond",
                        CrashSheetModel(summary: withFile, target: .pond, pondOffered: true, preview: galleryReport(withFile))),
        crashSheetScene("crash-sheet-pond-failed", failed),
        crashSheetScene("crash-sheet-no-report",
                        CrashSheetModel(summary: GalleryFixtures.hang, target: .pond, pondOffered: true,
                                        preview: galleryReport(GalleryFixtures.hang))),
    ]
}
