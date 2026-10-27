import AppKit
import RelayCore
import RelayUI
import SwiftUI

/// A step with a file row (current), a step with a script Hook won't open (opened by hand), a detail in
/// inline Markdown, and a Links section with a local path beside a web link.
func filesJSON(host: String) -> String {
    #"""
    {"item": {"id": "00000000-0000-4000-8000-0000000000f1", "title": "Read the release plan before Friday",
      "status": "open", "projectId": "Kestrel", "created": "2026-10-16T09:30:00+00:00", "updated": "2026-10-16T09:30:00+00:00",
      "payload": {"instructable": {"v": 1, "title": "Read the release plan before Friday", "urgency": "today",
        "why": "The plan changed after Tuesday's review.",
        "steps": [{"do": "Read the release plan", "file": "/Users/me/Documents/Plans/release-plan.md",
                   "detail": "Check the **dates** and the *rollback* section, and the `beta` flag.\nQuestions go in the [tracker](https://tracker.example.com/42)."},
                  {"do": "Look at the setup script", "file": "~/Documents/Plans/setup.command"},
                  {"do": "Tell us what to change", "question": {"prompt": "Anything to change in the plan?"}}],
        "links": [{"label": "Release plan", "path": "~/Documents/Plans/release-plan.md"},
                  {"label": "Status page", "url": "https://status.example.com"}],
        "from": {"session": "1b2c3d4e-0000-4000-8000-000000000001", "host": "\#(host)", "cwd": "/work/kestrel"}}}},
     "events": []}
    """#
}

/// The gallery's file actions: nothing opens and no app lookups. Rows never check the file
/// to render, so a missing file only shows after a click; the gallery shows the states a
/// path alone decides (a script refused, a link from another machine).
let galleryFiles = FileActions(check: { _ in .missing }, open: { _ in }, openWith: { _, _ in },
                               openWithOther: { _ in }, reveal: { _ in }, apps: { _ in [] })

/// `filesJSON` from `host`, with step 2 opened by hand; this Mac is "example-mac".
@MainActor func filesScene(_ name: String, host: String) -> GalleryScene {
    var snapshot = detailSnapshot(decodeDetail(filesJSON(host: host)), base: GalleryFixtures.detailSteps)
    snapshot.replies = []
    snapshot.model?.reply = nil
    snapshot.unansweredCaption = AnswerDrafts.unansweredCaption(snapshot.model?.unanswered.count ?? 0)
    let model = FixturePanelModel(
        queue: GalleryFixtures.queue(grouping: .project, filter: nil, closedExpanded: false),
        details: [snapshot.id: snapshot],
        navigation: PanelNavigation(listSelection: snapshot.id, selectedID: snapshot.id), status: readyStatus)
    model.expandedTodo[snapshot.id] = ["2"]
    model.localHost = "example-mac"
    model.shell.files = galleryFiles
    return panelScene(name, model, height: nil, rules: topColumnRules, overrides: fullHeight)
}

/// A sample document for the viewer: headings, inline styles, lists, a task list, code, a
/// table, a quote, a web link, a script (stripped) and a remote image (not loaded).
let viewerSampleMarkdown = #"""
# Release plan

The beta goes to **everyone** on Friday. Read the *rollback* section first, and keep the `beta` flag on until Monday.

## Dates

| Day | What | Who |
|---|---|---|
| Wednesday | Freeze the build | Release team |
| Thursday | Staff-only beta | Everyone in the office |
| Friday | Public beta | Everyone |

## Before Friday

1. Check the crash reports from the staff beta.
2. Update the release notes.
3. Tell support what changed.

- [x] Build frozen
- [ ] Notes reviewed

> If anything looks wrong on Thursday, stop the rollout and post in the tracker.

## Rollback

```sh
kestrel rollout pause
kestrel rollout revert --to 4.2.1
```

More detail is on the [status page](https://status.example.com).

<script>document.title = "changed"</script>
![Rollout chart](https://images.example.com/chart.png)
"""#

/// The viewer window's content: `text` rendered as `kind`.
@MainActor func viewerScene(_ name: String, text: String, kind: DocumentKind, height: CGFloat) -> GalleryScene {
    GalleryScene(
        name: name, size: .web(NSSize(width: DS.Viewer.windowWidth, height: height)), standIn: false,
        view: { AnyView(EmptyView()) },
        web: {
            DocumentWebView(
                page: DocumentPage.html(text: text, kind: kind, title: "release-plan.md",
                                        stylesheet: DS.Viewer.stylesheet()),
                folder: nil)
        })
}

@MainActor let fileScenes: [GalleryScene] = [
    filesScene("detail-files", host: "example-mac"),
    filesScene("detail-files-other-mac", host: "studio-mac"),
    viewerScene("viewer-markdown", text: viewerSampleMarkdown, kind: .markdown, height: 760),
    viewerScene("viewer-plain", text: "Plain text keeps its spacing:\n\n  name      size\n  plan.md   4 KB\n",
                kind: .plain, height: 240),
]
