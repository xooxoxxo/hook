import CoreGraphics
import Testing
@testable import RelayCore

/// A 1440×900 primary display with a 25 pt menu bar and a 70 pt Dock at the bottom.
private let primary = DockScreen(
    id: "PRIMARY", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805), isPrimary: true)
/// A 1920×1080 display to the left of the primary one, at negative x.
private let leftOfPrimary = DockScreen(
    id: "LEFT", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isPrimary: false)
/// A 2560×1440 display to the right of the primary one, with a 200 pt gap.
private let farRight = DockScreen(
    id: "RIGHT", frame: CGRect(x: 1640, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1640, y: 0, width: 2560, height: 1415), isPrimary: false)
/// A display stacked above the primary one.
private let above = DockScreen(
    id: "ABOVE", frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 900), isPrimary: false)

@Suite struct DockTargetTests {
    @Test func thePinnedDisplayWinsWhenConnected() {
        #expect(DockGeometry.target(screens: [primary, leftOfPrimary], pinned: "LEFT") == leftOfPrimary)
    }

    @Test func aMissingPinnedDisplayFallsBackToThePrimary() {
        #expect(DockGeometry.target(screens: [leftOfPrimary, primary], pinned: "GONE") == primary)
        #expect(DockGeometry.target(screens: [leftOfPrimary, primary], pinned: nil) == primary)
    }

    @Test func withNoPrimaryTheFirstIsUsed() {
        #expect(DockGeometry.target(screens: [farRight, leftOfPrimary], pinned: "GONE") == farRight)
    }

    @Test func noDisplaysMeansNoTarget() {
        #expect(DockGeometry.target(screens: [], pinned: "LEFT") == nil)
        #expect(DockGeometry.target(screens: [], pinned: nil) == nil)
    }
}

@Suite struct DockFrameTests {
    @Test func leftIsFlushWithTheVisibleFrame() {
        #expect(DockGeometry.frame(edge: .left, on: primary, width: 380)
            == CGRect(x: 0, y: 70, width: 380, height: 805))
    }

    @Test func rightIsFlushWithTheVisibleFrame() {
        #expect(DockGeometry.frame(edge: .right, on: primary, width: 380)
            == CGRect(x: 1060, y: 70, width: 380, height: 805))
    }

    @Test func aDockOnTheLeftAndANegativeOriginAreRespected() {
        let screen = DockScreen(
            id: "D", frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1856, y: -200, width: 1856, height: 1055), isPrimary: false)
        #expect(DockGeometry.frame(edge: .left, on: screen, width: 380)
            == CGRect(x: -1856, y: -200, width: 380, height: 1055))
        #expect(DockGeometry.frame(edge: .right, on: screen, width: 380)
            == CGRect(x: -380, y: -200, width: 380, height: 1055))
    }
}

@Suite struct DockSnapTests {
    private func snap(_ x: CGFloat, _ y: CGFloat, _ screens: [DockScreen]) -> (String, SidebarEdge)? {
        DockGeometry.snap(point: CGPoint(x: x, y: y), screens: screens).map { ($0.screenID, $0.edge) }
    }

    @Test func theHalfPicksTheEdge() throws {
        let screens = [primary, farRight]
        let left = try #require(snap(100, 400, screens))
        #expect(left == ("PRIMARY", .left))
        let right = try #require(snap(1300, 400, screens))
        #expect(right == ("PRIMARY", .right))
        let otherRight = try #require(snap(4000, 400, screens))
        #expect(otherRight == ("RIGHT", .right))
    }

    @Test func aPointBetweenDisplaysGoesToTheNearest() throws {
        // In the 200 pt gap between the primary (ends at 1440) and RIGHT (starts at 1640).
        let nearPrimary = try #require(snap(1500, 400, [primary, farRight]))
        #expect(nearPrimary == ("PRIMARY", .right))
        let nearRight = try #require(snap(1600, 400, [primary, farRight]))
        #expect(nearRight == ("RIGHT", .left))
        // Above RIGHT's top but beside nothing else.
        let overTheTop = try #require(snap(1700, 1600, [primary, farRight]))
        #expect(overTheTop == ("RIGHT", .left))
    }

    @Test func aDisplayAtNegativeX() throws {
        let screens = [primary, leftOfPrimary]
        let farLeft = try #require(snap(-1800, 500, screens))
        #expect(farLeft == ("LEFT", .left))
        let innerHalf = try #require(snap(-100, 500, screens))
        #expect(innerHalf == ("LEFT", .right))
        let onPrimary = try #require(snap(10, 500, screens))
        #expect(onPrimary == ("PRIMARY", .left))
    }

    @Test func verticallyStackedDisplays() throws {
        let screens = [primary, above]
        let top = try #require(snap(1200, 1500, screens))
        #expect(top == ("ABOVE", .right))
        let bottom = try #require(snap(200, 300, screens))
        #expect(bottom == ("PRIMARY", .left))
        let aboveEverything = try #require(snap(300, 2500, screens))
        #expect(aboveEverything == ("ABOVE", .left))
    }

    @Test func noDisplaysMeansNoSnap() {
        #expect(snap(0, 0, []) == nil)
    }
}

@Suite struct DragTrackerTests {
    @Test func underTheThresholdIsAClick() {
        var tracker = DragTracker(threshold: 3)
        #expect(tracker.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1) == nil)
        #expect(tracker.mouseDragged(to: CGPoint(x: 12, y: 11)) == nil)
        #expect(tracker.mouseUp(at: CGPoint(x: 12, y: 11)) == .click)
    }

    @Test func pastTheThresholdItDrags() {
        var tracker = DragTracker(threshold: 3)
        _ = tracker.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        #expect(tracker.mouseDragged(to: CGPoint(x: 13, y: 10)) == .began)
        #expect(tracker.mouseDragged(to: CGPoint(x: 13, y: 10)) == .moved(CGSize(width: 3, height: 0)))
        #expect(tracker.mouseDragged(to: CGPoint(x: 40, y: -5)) == .moved(CGSize(width: 30, height: -15)))
        #expect(tracker.mouseUp(at: CGPoint(x: 41, y: -5)) == .ended(CGPoint(x: 41, y: -5)))
    }

    @Test func aVerticalDragCountsToo() {
        var tracker = DragTracker(threshold: 3)
        _ = tracker.mouseDown(at: .zero, clickCount: 1)
        #expect(tracker.mouseDragged(to: CGPoint(x: 0, y: -3)) == .began)
    }

    @Test func doubleClickRedocksAndItsMouseUpIsSilent() {
        var tracker = DragTracker(threshold: 3)
        #expect(tracker.mouseDown(at: .zero, clickCount: 2) == .doubleClick)
        #expect(tracker.mouseDragged(to: CGPoint(x: 50, y: 0)) == nil)
        #expect(tracker.mouseUp(at: .zero) == nil)
    }

    @Test func aStrayUpOrDragDoesNothing() {
        var tracker = DragTracker(threshold: 3)
        #expect(tracker.mouseDragged(to: CGPoint(x: 9, y: 9)) == nil)
        #expect(tracker.mouseUp(at: .zero) == nil)
        _ = tracker.mouseDown(at: .zero, clickCount: 1)
        _ = tracker.mouseDragged(to: CGPoint(x: 5, y: 0))
        tracker.cancel()
        #expect(tracker.mouseUp(at: .zero) == nil)
    }
}

@Suite struct DockTests {
    @Test func onlyTheEdgeOrTheDisplayNeedsADock() {
        let base = RelayConfig()
        #expect(!DockGeometry.needsDock(old: base, new: base))
        #expect(!DockGeometry.needsDock(old: nil, new: base))          // both mean right edge, main display
        #expect(DockGeometry.needsDock(old: base, new: RelayConfig(sidebarEdge: .left)))
        #expect(DockGeometry.needsDock(old: base, new: RelayConfig(sidebarDisplay: "LEFT")))
        #expect(DockGeometry.needsDock(old: RelayConfig(sidebarDisplay: "LEFT"), new: base))
        #expect(DockGeometry.needsDock(old: RelayConfig(sidebarDisplay: "LEFT"), new: nil))
    }

    @Test func unrelatedKeysNeverDock() {
        let base = RelayConfig()
        let edited = RelayConfig(pollSeconds: 30, showCount: false, appearance: .dark,
                                 notify: NotifySettings(sound: true), presence: .away)
        #expect(!DockGeometry.needsDock(old: base, new: edited))
    }

    @Test func aDragFollowsThePointerAtTheDockedSize() {
        let start = CGRect(x: 1060, y: 70, width: 380, height: 805)
        #expect(DockGeometry.dragFrame(start: start, delta: CGSize(width: -600, height: 20))
            == CGRect(x: 460, y: 90, width: 380, height: 805))
        #expect(DockGeometry.dragFrame(start: start, delta: .zero) == start)
        // Across onto a display at negative x, still 380 × 805.
        #expect(DockGeometry.dragFrame(start: start, delta: CGSize(width: -2500, height: -40))
            == CGRect(x: -1440, y: 30, width: 380, height: 805))
    }

    @Test func theCurrentDisplayHoldsThePanelsCentre() {
        let onPrimaryRight = CGRect(x: 1060, y: 70, width: 380, height: 805)
        #expect(DockGeometry.currentScreenID(frame: onPrimaryRight, screens: [primary, leftOfPrimary]) == "PRIMARY")
        let onLeft = CGRect(x: -1920, y: 0, width: 380, height: 1080)
        #expect(DockGeometry.currentScreenID(frame: onLeft, screens: [primary, leftOfPrimary]) == "LEFT")
        let onTop = CGRect(x: 1060, y: 900, width: 380, height: 900)
        #expect(DockGeometry.currentScreenID(frame: onTop, screens: [primary, above]) == "ABOVE")
    }

    @Test func aCentreInAGapPicksTheLargestOverlap() {
        // Centre at x = 1530 sits in the gap between PRIMARY (ends 1440) and RIGHT (starts 1640).
        let straddling = CGRect(x: 1340, y: 100, width: 380, height: 600)
        #expect(DockGeometry.currentScreenID(frame: straddling, screens: [primary, farRight]) == "PRIMARY")
        let nowhere = CGRect(x: 9000, y: 9000, width: 380, height: 600)
        #expect(DockGeometry.currentScreenID(frame: nowhere, screens: [primary, farRight]) == nil)
        #expect(DockGeometry.currentScreenID(frame: straddling, screens: []) == nil)
    }
}
