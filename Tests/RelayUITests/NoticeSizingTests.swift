import AppKit
import RelayCore
import SwiftUI
import Testing
@testable import RelayUI

/// A Notice always gets the height of its whole content: in a column that is short of room
/// it keeps that height and the view below it starts after it, its text is never cut to a
/// line limit, and larger text makes it taller instead of clipping it.
@Suite @MainActor struct NoticeSizingTests {
    private final class Frames {
        var notice: CGRect = .zero
        var below: CGRect = .zero
    }

    private static let width = DS.Metric.panelWidth - 2 * DS.Space.gutter
    private static let space = "column"

    private static func olderNotice() -> Notice {
        let notice = PanelNotice.mailboxOlder(missing: MailboxFeature.allCases)
        return Notice(kind: notice.kind, text: notice.text, actionTitle: notice.actionTitle, help: notice.help,
                      secondaryTitle: notice.secondaryActionTitle, onAction: {}, onDismiss: {})
    }

    private static func oneButtonNotice() -> Notice {
        Notice(kind: .info, text: "Offline · showing asks from 09:22", actionTitle: "Try Again", onAction: {}, onDismiss: {})
    }

    /// The Notice's own height at `width`.
    private static func idealHeight(_ notice: Notice, width: CGFloat = width) -> CGFloat {
        NSHostingController(rootView: notice.frame(width: width))
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }

    private static func frame(_ frames: Frames, _ set: @escaping (Frames, CGRect) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear.onAppear { set(frames, proxy.frame(in: .named(space))) }
        }
    }

    /// The Notice above a view that wants far more room than the column has, as the queue's
    /// List does, in a column `height` points tall.
    private static func layOut(_ notice: Notice, height: CGFloat, width: CGFloat = width) -> Frames {
        let frames = Frames()
        let column = VStack(spacing: 0) {
            notice.background(frame(frames) { $0.notice = $1 })
            Color.clear.frame(minHeight: 40, idealHeight: 2_000, maxHeight: .infinity)
                .background(frame(frames) { $0.below = $1 })
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: space)
        let host = NSHostingView(rootView: column)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // onAppear reports the frames on a later run-loop turn; a slow runner needs more than one.
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        } while (frames.notice == .zero || frames.below == .zero) && Date() < deadline
        window.contentView = nil
        return frames
    }

    @Test(arguments: [false, true]) func keepsItsHeightInAShortColumn(twoButtons: Bool) {
        let notice = twoButtons ? Self.olderNotice() : Self.oneButtonNotice()
        let ideal = Self.idealHeight(notice)
        let frames = Self.layOut(notice, height: ideal + 60)
        #expect(abs(frames.notice.height - ideal) < 0.5, "got \(frames.notice.height), needs \(ideal)")
        #expect(frames.notice.minY >= 0)
        #expect(frames.below.minY >= frames.notice.maxY - 0.5)
    }

    @Test func textIsNotCutToALineLimit() {
        func notice(_ sentences: Int) -> Notice {
            Notice(kind: .error, text: String(repeating: "Couldn't save the queue. The disk is full. ", count: sentences),
                   actionTitle: nil, onAction: {}, onDismiss: {})
        }
        // Both are well past three lines at panel width and within Notice.maxLines, so the
        // longer one must be taller.
        #expect(Self.idealHeight(notice(8)) > Self.idealHeight(notice(4)))
    }

    /// More lines (larger text, or less width: the gallery's --xl renders show the former;
    /// the global text scale isn't changed here, other suites run alongside) make it taller.
    @Test func moreLinesMakeItTaller() {
        let narrow = Self.width * 0.6
        let normal = Self.idealHeight(Self.olderNotice())
        let tall = Self.idealHeight(Self.olderNotice(), width: narrow)
        #expect(tall > normal)
        let frames = Self.layOut(Self.olderNotice(), height: tall + 60, width: narrow)
        #expect(abs(frames.notice.height - tall) < 0.5)
        #expect(frames.below.minY >= frames.notice.maxY - 0.5)
    }
}
