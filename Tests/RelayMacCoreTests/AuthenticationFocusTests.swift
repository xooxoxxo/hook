import AppKit
import Testing
@testable import RelayMacCore

@Suite @MainActor struct AuthenticationFocusTests {
    @Test func authenticationHandoffRestoresOnce() {
        let center = NotificationCenter()
        var returns = 0
        let focus = AuthenticationFocus(window: nil, center: center, workspace: center, distributed: center,
                                        canRestore: { true }, restore: { returns += 1 })
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        focus.activatedOtherApplication(isRegular: false)
        focus.finish(confirmed: true)
        focus.finish(confirmed: true)
        #expect(returns == 1)
    }

    @Test(arguments: [NSApplication.didHideNotification, NSWorkspace.sessionDidResignActiveNotification,
                      NSWorkspace.screensDidSleepNotification, Notification.Name("com.apple.screenIsLocked")])
    func leavingOrLockingPreventsLateFocusReturn(_ event: Notification.Name) {
        let center = NotificationCenter()
        var returns = 0
        let focus = AuthenticationFocus(window: nil, center: center, workspace: center, distributed: center,
                                        canRestore: { true }, restore: { returns += 1 })
        center.post(name: event, object: nil)
        focus.finish(confirmed: true)
        #expect(returns == 0)
    }

    @Test func switchingAppsPreventsReturnEvenAfterSwitchingBack() {
        let center = NotificationCenter()
        var returns = 0
        let focus = AuthenticationFocus(window: nil, center: center, workspace: center, distributed: center,
                                        canRestore: { true }, restore: { returns += 1 })
        focus.activatedOtherApplication(isRegular: true)
        focus.activatedOtherApplication(isRegular: false)
        focus.finish(confirmed: true)
        #expect(returns == 0)
    }

    @Test(arguments: [false, true])
    func failedOrNoLongerVisibleDoesNotReturn(_ confirmed: Bool) {
        let center = NotificationCenter()
        var returns = 0
        let focus = AuthenticationFocus(window: nil, center: center, workspace: center, distributed: center,
                                        canRestore: { !confirmed }, restore: { returns += 1 })
        focus.finish(confirmed: confirmed)
        #expect(returns == 0)
    }

    @Test func onlyTheInitiatingWindowClosingCancelsReturn() {
        let center = NotificationCenter()
        let origin = NSWindow(), systemWindow = NSWindow()
        for closeOrigin in [false, true] {
            var returns = 0
            let focus = AuthenticationFocus(window: origin, center: center, workspace: center, distributed: center,
                                            canRestore: { true }, restore: { returns += 1 })
            center.post(name: NSWindow.willCloseNotification, object: closeOrigin ? origin : systemWindow)
            focus.finish(confirmed: true)
            #expect(returns == (closeOrigin ? 0 : 1))
        }
    }
}
