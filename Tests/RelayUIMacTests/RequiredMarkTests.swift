import AppKit
import Foundation
@testable import RelayCore
import SwiftUI
import Testing
@testable import RelayUI
@testable import RelayUIMac

private typealias Steps = DetailSteps<FixturePanelModel>
private typealias Messages = DetailMessages<FixturePanelModel>
private typealias Reply = DetailReply<FixturePanelModel>
private typealias Detail = DetailView<FixturePanelModel>

/// `snapshot` rebuilt with `ticks` (and any extra owner events), as the Store would.
private func rebuilt(_ json: String, ticks: Set<String>) -> DetailSnapshot {
    RequiredFixtures.snapshot(json, ticks: ticks)
}

/// The distinct, laid-out frames of `role` (a reader that appeared before layout reports zero), left to right.
func shown(_ probes: [ProbeFrame], _ role: ProbeRole) -> [CGRect] {
    var out: [CGRect] = []
    for frame in probes where frame.role == role && frame.frame.width > 0 && !out.contains(frame.frame) {
        out.append(frame.frame)
    }
    return out.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
}

private let leftJSON = RequiredFixtures.json(done: #"["reply", "message"]"#, reply: RequiredFixtures.freeReply,
                                             events: "")

/// Owner pick 1: Done is off while something is left, with no caption and no checklist; the
/// required items carry a badge and a row hue (never a "Required" label) until finished.
@Suite @MainActor struct RequiredMarkTests {
    // MARK: The step marks

    @Test func theBadgeAndHueShowOnAMarkedStepAndGoOnceItIsFinished() {
        let left = RequiredFixtures.full(ready: false)
        // Step 1 is required and ticked: it reads like any finished row. 4 isn't required, 4a is.
        #expect(RequiredMark.stepPaths(left.requirements) == ["2", "3", "4.1"])
        #expect(RequiredMark.stepPaths(rebuilt(leftJSON, ticks: ["1", "2"]).requirements) == ["3", "4.1"])
        #expect(RequiredMark.stepPaths(rebuilt(leftJSON, ticks: ["1", "2", "4.1"]).requirements) == ["3"])
        #expect(RequiredMark.stepPaths(RequiredFixtures.full(ready: true).requirements).isEmpty)
        // An ask without requirements marks nothing.
        #expect(RequiredMark.stepPaths(GalleryFixtures.detailSteps.requirements).isEmpty)
    }

    @Test func aParentMarksOnlyItsHeader() {
        // done: steps makes every top-level step required; parent 4's sub-steps are not, on their own.
        let steps = RequiredFixtures.fullSteps.replacingOccurrences(
            of: #""do": "Paste the public key into the job settings", "required": true"#,
            with: #""do": "Paste the public key into the job settings""#)
        #expect(steps != RequiredFixtures.fullSteps)
        let json = RequiredFixtures.json(done: #"["steps"]"#, reply: RequiredFixtures.freeReply, steps: steps,
                                         events: "")
        let snapshot = rebuilt(json, ticks: ["1", "2"])
        let marked = RequiredMark.stepPaths(snapshot.requirements)
        #expect(marked.contains("4") && !marked.contains("4.1") && !marked.contains("4.2"))
        let parent = ParentStepView.requiredMarks(own: marked.contains("4"), childPaths: ["4.1", "4.2"], marked: marked)
        #expect(parent.header && parent.children == [false, false])
        // A required sub-step under a parent that isn't: only that sub-step's row.
        let left = RequiredFixtures.full(ready: false)
        let sub = ParentStepView.requiredMarks(own: false, childPaths: ["4.1", "4.2"],
                                               marked: RequiredMark.stepPaths(left.requirements))
        #expect(!sub.header && sub.children == [true, false])
    }

    // MARK: The badge's ring (0.13 low finding: dark-mode contrast on the current step)

    /// The current step's tick marker with its badge, on the required row's surface, rendered in
    /// `scheme` at `textSize`; returns the run of non-accent points between the dot and the
    /// marker along the line from the badge's centre to the marker's, or nil when that line never
    /// reaches the marker. At the gallery's --xl sizes the marker grows into the badge.
    private func ringGap(_ scheme: ColorScheme, textSize: CGFloat) throws -> CGFloat? {
        let size = NSSize(width: 240, height: 80), inset: CGFloat = 16
        let sink = AlignmentProbeSink()
        let row = ZStack(alignment: .topLeading) {
            DS.Color.panelStandInOpaque
            DS.Color.groupFill
            DS.Color.requiredRow
            // As StepView lays out a step's first line.
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.marker) {
                TickButton(level: .top(2), state: .current, label: "2", hint: "", value: "", help: "", readOnly: false,
                           action: {})
                    .requiredBadge(true)
                Text(verbatim: "Mac terminal")
            }
            .font(.system(size: textSize))
            .padding(.leading, inset)
            .padding(.top, inset)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
        .environment(\.alignmentProbesEnabled, true)
        .environment(\.alignmentProbeSink, sink)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        } while (shown(sink.frames, .requiredBadge).isEmpty || shown(sink.frames, .topMarker).isEmpty) && Date() < deadline
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        let bitmap = try #require(InkBitmap(rep))
        let badgeFrame = try #require(shown(sink.frames, .requiredBadge).last)
        let markerFrame = try #require(shown(sink.frames, .topMarker).last)
        let badge = CGPoint(x: badgeFrame.midX, y: badgeFrame.midY)
        let marker = CGPoint(x: markerFrame.midX, y: markerFrame.midY)
        func pixel(_ p: CGPoint) -> UInt32 {
            let x = min(bitmap.width - 1, max(0, Int(p.x * bitmap.scale)))
            let y = min(bitmap.height - 1, max(0, Int(p.y * bitmap.scale)))
            return bitmap.pixels[y * bitmap.width + x]
        }
        let accent = pixel(badge)
        let length = hypot(marker.x - badge.x, marker.y - badge.y)
        let step = 1 / bitmap.scale
        var t: CGFloat = 0, gap: CGFloat = 0, leftDot = false
        while t <= length {
            let p = CGPoint(x: badge.x + (marker.x - badge.x) * t / length, y: badge.y + (marker.y - badge.y) * t / length)
            if !bitmap.differs(pixel(p), accent, threshold: 40) {
                if leftDot { return gap }
            } else {
                leftDot = true
                gap += step
            }
            t += step
        }
        return nil
    }

    @Test func badgeRingSeparatesFromCurrentMarkerDark() throws {
        for scheme in [ColorScheme.dark, .light] {
            for textSize: CGFloat in [13, 17.5] {          // the panel's size, and the gallery's --xl
                let gap = try ringGap(scheme, textSize: textSize)
                #expect(gap != nil, "\(scheme) \(textSize): the line from the badge never reached the marker")
                #expect((gap ?? 0) >= 1, "\(scheme) \(textSize): \(gap ?? 0) pt between the dot and the marker")
            }
        }
    }

    // MARK: Messages and the reply

    @Test func messagesAndTheReplyAreMarkedOnlyWhileLeft() {
        let left = RequiredFixtures.full(ready: false), ready = RequiredFixtures.full(ready: true)
        #expect(Messages.marked(left) && Reply.marked(left))
        #expect(!Messages.marked(ready) && !Reply.marked(ready))
        #expect(Messages.marked(RequiredFixtures.messageLeft) && !Reply.marked(RequiredFixtures.messageLeft))
        #expect(Reply.marked(RequiredFixtures.replyLeft) && !Messages.marked(RequiredFixtures.replyLeft))
        #expect(!Messages.marked(GalleryFixtures.detailSteps) && !Reply.marked(GalleryFixtures.detailSteps))
        #expect(RequiredMark.headingValue(true) == "required")
        #expect(RequiredMark.headingValue(false) == nil)
    }

    @Test func theMessageFieldIsInlineWhenDoneHoldsMessage() {
        // A reply prompt would put the field behind the disclosure (RD 27).
        #expect(RequiredFixtures.messageLeft.model?.reply != nil)
        #expect(Messages.fieldPlacement(RequiredFixtures.messageLeft) == .inline)
        #expect(Messages.fieldPlacement(RequiredFixtures.full(ready: false)) == .inline)
        // Still inline once a message went: the field doesn't jump behind a disclosure.
        #expect(Messages.fieldPlacement(RequiredFixtures.full(ready: true)) == .inline)
        // Without `done: message`, a reply prompt keeps it disclosed.
        #expect(Messages.fieldPlacement(RequiredFixtures.replyLeft) == .disclosed)
    }

    // MARK: VoiceOver

    @Test func voiceOverLabelsEndInRequiredOnlyWhileMarked() {
        #expect(StepAccessibility.required("Generate a new deploy key", true) == "Generate a new deploy key, required")
        #expect(StepAccessibility.required("Generate a new deploy key", false) == "Generate a new deploy key")
        let node = RequiredFixtures.full(ready: false).model!.nodes[1]
        #expect(Steps.rotorTitle(node, required: true) == "2. Generate a new deploy key, required")
        #expect(Steps.rotorTitle(node, required: false) == "2. Generate a new deploy key")
        let optional = RequiredFixtures.full(ready: false).model!.nodes[4]
        #expect(Steps.rotorTitle(optional, required: false) == "5. Delete the old key file, optional")
    }

    /// No string a detail view draws says "Required": the mark is the badge and the hue.
    @Test func noDetailViewRendersTheWordRequired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #""[^"\n]*\bRequired\b[^"\n]*""#)
        var hits: [String] = []
        for folder in ["RelayUI/Design", "RelayUIMac/Panel"] {
            let dir = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty, "\(folder)")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if pattern.firstMatch(in: line, range: range) != nil {
                        hits.append("\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    // MARK: The action bar

    @Test func doneIsOffWithItsHelpAsHelpAndHint() {
        let help = Requirements.doneHelp(RequiredFixtures.full(ready: false).requirements)
        let buttons = ActionBar.buttons(.open(.done), doneEnabled: false, discardEnabled: true, doneHelp: help)
        #expect(buttons.map(\.title) == ["Skip", "Done"])
        let done = buttons[1]
        #expect(!done.enabled && done.prominent)
        #expect(done.help == help && done.hint == help)
        let on = ActionBar.buttons(.open(.done), doneEnabled: true, discardEnabled: true, doneHelp: help)[1]
        #expect(on.enabled && on.help == ActionBar.primaryHelp(.done) && on.hint == nil)
    }

    @Test func discardAndDoneIsOffWhenTheDraftsAloneFinishIt() {
        let buttons = ActionBar.buttons(.warning(.answer, busy: false), doneEnabled: true, discardEnabled: false,
                                        doneHelp: "why")
        #expect(buttons.map(\.title) == [ActionBar.discardTitle, ActionBar.sendAndDoneTitle])
        #expect(!buttons[0].enabled && buttons[1].enabled && buttons[1].prominent)
        let both = ActionBar.buttons(.warning(.answer, busy: false), doneEnabled: true, discardEnabled: true,
                                     doneHelp: "why")
        #expect(both.allSatisfy { $0.enabled })
    }

    @Test func skipIsOnInEveryCase() {
        for done in [false, true] {
            for discard in [false, true] {
                for action in [PrimaryAction.done, .sendAndDone] {
                    let skip = ActionBar.buttons(.open(action), doneEnabled: done, discardEnabled: discard,
                                                 doneHelp: "why")[0]
                    #expect(skip.title == "Skip" && skip.enabled, "\(done) \(discard) \(action)")
                }
            }
        }
    }

    @Test func theDetailHandsTheBarItsGate() {
        let left = Detail.gate(RequiredFixtures.full(ready: false))
        #expect(!left.doneEnabled && !left.discardEnabled)
        #expect(left.doneHelp == "Done turns on once the marked items are finished. Skip always works.")
        let ready = Detail.gate(RequiredFixtures.full(ready: true))
        #expect(ready.doneEnabled && ready.discardEnabled)
        // No caption on an ask with requirements (RD 24).
        #expect(Detail.answers(RequiredFixtures.full(ready: false)).caption == nil)
        #expect(Detail.answers(RequiredFixtures.full(ready: true)).caption == nil)
    }

    /// Skip, Done, Send & Done and Discard & Done are each at least `barButtonMinWidth` wide,
    /// and two of them fit beside each other at the panel's width.
    @Test(arguments: [ActionBarMode.open(.done), .open(.sendAndDone), .warning(.answer, busy: false)])
    func everyBarButtonIsAtLeastTheMinimumWidth(mode: ActionBarMode) {
        let sink = AlignmentProbeSink()
        let width = DS.Metric.panelWidth
        let bar = ActionBar(mode: mode, doneEnabled: false, discardEnabled: false, doneHelp: "why",
                            onSkip: {}, onPrimary: {}, onReopen: {})
            .frame(width: width)
            .environment(\.alignmentProbesEnabled, true)
            .environment(\.alignmentProbeSink, sink)
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: 0, y: 0, width: width, height: DS.Metric.actionBar)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        } while shown(sink.frames, .barButton).count < 2 && Date() < deadline
        window.contentView = nil
        let frames = shown(sink.frames, .barButton)
        #expect(frames.count == 2)
        for frame in frames { #expect(frame.width >= DS.Metric.barButtonMinWidth - 0.5, "\(frame)") }
        if frames.count == 2 {
            #expect(frames[0].maxX < frames[1].minX)
            #expect(frames[1].maxX <= width - DS.Space.gutter + 0.5)
            #expect(frames[0].minX >= DS.Space.gutter - 0.5)
        }
    }
}
