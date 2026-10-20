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

    @Test func theSlideStartsJustBeyondItsEdge() {
        let left = CGRect(x: 0, y: 70, width: 380, height: 805)
        #expect(SlideIn.offscreenFrame(docked: left, edge: .left) == CGRect(x: -380, y: 70, width: 380, height: 805))
        #expect(SlideIn.offscreenFrame(docked: docked, edge: .right) == CGRect(x: 1440, y: 70, width: 380, height: 805))
        let negative = CGRect(x: -1920, y: 0, width: 380, height: 1080)
        #expect(SlideIn.offscreenFrame(docked: negative, edge: .left) == CGRect(x: -2300, y: 0, width: 380, height: 1080))
    }

    @Test func itSlidesOnlyWhileHomeWithSlideInOnAndThePanelHidden() {
        #expect(SlideIn.shouldSlide(home: true, slideInOn: true, panelVisible: false))
        #expect(!SlideIn.shouldSlide(home: false, slideInOn: true, panelVisible: false))
        #expect(!SlideIn.shouldSlide(home: true, slideInOn: false, panelVisible: false))
        #expect(!SlideIn.shouldSlide(home: true, slideInOn: true, panelVisible: true))
    }

    @Test func theAnnouncementNamesTheProjectOnlyOutsideTheFilter() {
        #expect(SlideIn.announcement(title: "Rotate the key", project: "Acme", outsideFilter: false)
            == "New Now ask: Rotate the key")
        #expect(SlideIn.announcement(title: "Rotate the key", project: "Acme", outsideFilter: true)
            == "New Now ask in Acme: Rotate the key")
    }

    @Test func theAnnouncementIsOneRevealedLine() {
        let text = SlideIn.announcement(title: "two\nlines", project: "Ac\u{202E}me", outsideFilter: true)
        #expect(text == "New Now ask in Ac⟨U+202E⟩me: two⟨U+000A⟩lines")
    }
}
