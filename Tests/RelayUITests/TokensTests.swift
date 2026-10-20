import AppKit
import SwiftUI
import Testing
@testable import RelayUI

@Suite struct TokensTests {
    @Test func spacingMatchesTheSpec() {
        let s = DS.Space.self
        #expect([s.rowLine, s.rowInsetV, s.rowInsetH, s.sectionHeaderLead, s.stepPart, s.inline, s.marker, s.step]
            == [4, 6, 0, 2, 6, 8, 10, 16])
        #expect([s.subIndent, s.subStep, s.section, s.gutter, s.bodyV, s.codeH, s.codeV, s.currentStep]
            == [38, 10, 24, 16, 16, 10, 8, 4])
        #expect([s.currentBleed, s.emptyLine, s.popover] == [9, 24, 16])
    }

    @Test func metricsMatchTheSpec() {
        let m = DS.Metric.self
        #expect([m.panelWidth, m.header, m.filterRow, m.filterTokenMax, m.statusBar, m.undoBar, m.actionBar, m.hit]
            == [380, 44, 32, 160, 36, 36, 56, 28])
        #expect([m.rowProgress, m.codeRadius, m.helpWidth, m.settingsWidth, m.settingsInset, m.fieldWide, m.welcomeWidth]
            == [44, 6, 300, 600, 120, 320, 480])
        #expect([m.badge, m.badgeDot, m.dragThreshold, m.recorderMin, m.rowMinHeight] == [13, 7, 3, 130, 28])
    }

    @Test func derivedTokensHold() {
        #expect(DS.Space.subIndent == DS.Metric.hit + DS.Space.marker)
        #expect(DS.Space.currentBleed == 5 + DS.Space.currentStep)
        #expect(DS.Metric.rowMinHeight == DS.Metric.hit)
    }

    @Test func motion() {
        #expect(DS.Motion.push == .easeOut(duration: 0.22))
        #expect(DS.Motion.step == .easeInOut(duration: 0.20))
        #expect(DS.Motion.reveal == .easeOut(duration: 0.18))
        #expect(DS.Motion.reduced == .easeOut(duration: 0.12))
        #expect([DS.Motion.slideIn, DS.Motion.fade, DS.Motion.snap, DS.Motion.redockDebounce] == [0.25, 0.12, 0.20, 0.25])
        #expect([DS.Motion.wakeRecheck, DS.Motion.copiedFor, DS.Motion.undoHold] == [1.0, 1.5, 10])
        #expect(DS.Motion.sentHold == 4)
        #expect(DS.motion(DS.Motion.push, reduce: true) == DS.Motion.reduced)
        #expect(DS.motion(DS.Motion.push, reduce: false) == DS.Motion.push)
        #expect(DS.appKitDuration(DS.Motion.snap, reduce: true) == 0)
        #expect(DS.appKitDuration(DS.Motion.fade, reduce: true) == 0)
        #expect(DS.appKitDuration(DS.Motion.slideIn, reduce: true) == DS.Motion.fade)
        #expect(DS.appKitDuration(DS.Motion.snap, reduce: false) == DS.Motion.snap)
    }

    @Test func timing() {
        #expect(DS.Timing.closedWindow == 24 * 3600)
        #expect(DS.Timing.staleList == 5)
        #expect(DS.Timing.linkRecheck == 5)
        #expect(DS.Timing.holdTick == 1)
        #expect(DS.Timing.lastCallRefresh == 30)
    }

    @Test func controlSizes() {
        #expect(DS.Control.action == .large)
        #expect(DS.Control.form == .regular)
        #expect(DS.Control.inline == .small)
    }

    @Test func symbolsExistOnThisSystem() {
        let names = [
            DS.Symbol.now, DS.Symbol.today, DS.Symbol.whenever, DS.Symbol.stepTodo(1), DS.Symbol.stepTodo(20),
            DS.Symbol.stepCurrent(20), DS.Symbol.stepDone, DS.Symbol.subTodo, DS.Symbol.subCurrent, DS.Symbol.subDone,
            DS.Symbol.disclosureClosed, DS.Symbol.disclosureOpen, DS.Symbol.filter, DS.Symbol.filterOn,
            DS.Symbol.clearFilter, DS.Symbol.verifyTodo, DS.Symbol.verifyCurrent, DS.Symbol.verifyDone, DS.Symbol.expect,
            DS.Symbol.openLink, DS.Symbol.back, DS.Symbol.prev, DS.Symbol.next, DS.Symbol.refresh, DS.Symbol.settings,
            DS.Symbol.hide, DS.Symbol.draft, DS.Symbol.statusOK, DS.Symbol.statusDown, DS.Symbol.away, DS.Symbol.error,
            DS.Symbol.info, DS.Symbol.empty, DS.Symbol.offline, DS.Symbol.notSetUp, DS.Symbol.notFound,
            DS.Symbol.menuBar, DS.Symbol.link, DS.Symbol.warning, DS.Symbol.sent, DS.Symbol.clearShortcut,
            DS.Symbol.tabGeneral, DS.Symbol.tabPanel, DS.Symbol.tabQueue, DS.Symbol.tabNotifications, DS.Symbol.tabConnect,
        ]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
        #expect(DS.Symbol.stepTodo(3) == "3.circle")
        #expect(DS.Symbol.stepCurrent(3) == "3.circle.fill")
    }

    @Test func appKitValues() {
        #expect(DS.Color.badge == NSColor.systemRed)
        #expect(DS.Color.panelMaterial == .sidebar)
        #expect(DS.Font.badgeDigit.pointSize == 9)
    }
}
