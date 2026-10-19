import CoreGraphics
import Foundation
import Testing
@testable import RelayCore

/// The right-docked frame on a 1440×900 display with a 25 pt menu bar and a 70 pt Dock.
private let docked = CGRect(x: 1060, y: 70, width: 380, height: 805)

@Suite struct PanelWindowLogicTests {
    @Test func aHiddenPanelShowsWithFocus() {
        #expect(PanelToggle.decide(visible: false, isKey: false, frame: docked, target: docked) == .showAndFocus)
        #expect(PanelToggle.decide(visible: false, isKey: true, frame: .zero, target: docked) == .showAndFocus)
    }

    @Test func aVisiblePanelWithoutFocusTakesFocusAndStays() {
        #expect(PanelToggle.decide(visible: true, isKey: false, frame: docked, target: docked) == .focus)
    }

    @Test func aFocusedDockedPanelHides() {
        #expect(PanelToggle.decide(visible: true, isKey: true, frame: docked, target: docked) == .hide)
        // Half a point or less still counts as docked.
        let nudged = docked.offsetBy(dx: 0.5, dy: -0.4)
        #expect(PanelToggle.decide(visible: true, isKey: true, frame: nudged, target: docked) == .hide)
    }

    @Test func aMisplacedPanelRedocksInsteadOfHiding() {
        let moved = docked.offsetBy(dx: -600, dy: 0)
        #expect(PanelToggle.decide(visible: true, isKey: true, frame: moved, target: docked) == .redockAndFocus)
        #expect(PanelToggle.decide(visible: true, isKey: false, frame: moved, target: docked) == .redockAndFocus)
        let shorter = CGRect(x: 1060, y: 70, width: 380, height: 700)
        #expect(PanelToggle.decide(visible: true, isKey: true, frame: shorter, target: docked) == .redockAndFocus)
        let wider = CGRect(x: 1060, y: 70, width: 381, height: 805)
        #expect(PanelToggle.decide(visible: true, isKey: true, frame: wider, target: docked) == .redockAndFocus)
    }
}
