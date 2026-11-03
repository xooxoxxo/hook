import AppKit
import RelayCore
import RelayUI
import SwiftUI

// Talking to the posting session (0.12): Report a Problem on a step (pick 3 B) and the
// Messages section (pick 4 A). Generic text only.

/// A step ask with step ids (reports need them): step 1 done, step 2 current with code.
let reportStepsJSON = #"""
{"item": {"id": "00000000-0000-4000-8000-0000000012a1", "title": "Rotate the staging deploy key",
  "status": "open", "projectId": "Atlas", "created": "2026-10-16T07:40:00+00:00", "updated": "2026-10-16T07:40:00+00:00",
  "payload": {"instructable": {"v": 1, "title": "Rotate the staging deploy key", "urgency": "today",
    "why": "The old key expires on Friday and the deploy job will stop.",
    "steps": [{"id": "s1", "do": "Open the staging vault", "url": "https://vault.example.com/staging"},
              {"id": "s2", "do": "Generate a new deploy key", "where": "Mac terminal",
               "code": "ssh-keygen -t ed25519 -f ~/.ssh/atlas-deploy -C deploy@staging",
               "expect": "Your identification has been saved"},
              {"id": "s3", "do": "Paste the public key into the vault"}],
    "verify": {"do": "Check a dry-run deploy", "code": "atlas deploy --dry-run"},
    "from": {"session": "1b2c3d4e-0000-4000-8000-000000000001", "host": "example-mac", "cwd": "/work/atlas"}}}},
 "events": []}
"""#

/// The report fixture on a Pond: step 1 ticked, so step 2 is current and open.
@MainActor func reportSnapshot(target: String? = nil, reported: Set<String> = [], keyReady: Bool = true,
                               state: ReportBoxState = .idle) -> DetailSnapshot {
    var snapshot = detailSnapshot(decodeDetail(reportStepsJSON), base: GalleryFixtures.detailSteps, ticks: ["1"])
    snapshot.replies = []
    snapshot.model?.reply = nil
    snapshot.canReport = true
    snapshot.reportTarget = target
    snapshot.reported = reported
    snapshot.ownerKeyReady = keyReady
    snapshot.report = state
    return snapshot
}

@MainActor func reportScene(_ name: String, _ snapshot: DetailSnapshot) -> GalleryScene {
    detailScene(name, snapshot, height: nil, rules: topColumnRules, overrides: fullHeight)
}

@MainActor let talkScenes: [GalleryScene] = [
    // Report on the current (open) step only; collapsed rows stay clean.
    reportScene("detail-step-report-open", reportSnapshot()),
    // The composer docked above the action bar, its step outlined.
    reportScene("detail-step-report-composer", reportSnapshot(target: "2")),
    // Step 1 reported: only the icon, no caption.
    reportScene("detail-step-reported", reportSnapshot(reported: ["1"])),
    // No approved owner key: Send reads Set Up Owner Key….
    reportScene("detail-step-report-no-key", reportSnapshot(target: "2", keyReady: false)),
    reportScene("detail-step-report-held", reportSnapshot(target: "2", keyReady: false, state: .held)),
]
