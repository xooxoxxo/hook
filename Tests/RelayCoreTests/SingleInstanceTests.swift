import Foundation
import Testing
@testable import RelayCore

private let relay = "io.github.xooxoxxo.relay"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func copy(_ pid: Int32, _ seconds: Double?, bundleID: String? = relay) -> SingleInstance.Copy {
    SingleInstance.Copy(bundleID: bundleID, pid: pid, started: seconds.map { t0.addingTimeInterval($0) })
}

@Suite struct SingleInstanceTests {
    @Test func aLaterCopyHandsOffToTheEarlierOne() {
        let running = [copy(100, nil, bundleID: "com.apple.finder"), copy(200, 0), copy(300, 5)]
        #expect(SingleInstance.older(than: copy(300, 5), running: running) == 200)
    }

    /// Two copies started together: only the later one leaves, so one always stays.
    @Test func theEarlierCopyStays() {
        let running = [copy(200, 0), copy(300, 5)]
        #expect(SingleInstance.older(than: copy(200, 0), running: running) == nil)
    }

    @Test func theEarliestOfSeveralIsChosen() {
        let running = [copy(400, 9), copy(300, 2), copy(200, 4)]
        #expect(SingleInstance.older(than: copy(400, 9), running: running) == 300)
    }

    @Test func theSameStartTimeFallsBackToThePid() {
        let running = [copy(200, 0), copy(300, 0)]
        #expect(SingleInstance.older(than: copy(300, 0), running: running) == 200)
        #expect(SingleInstance.older(than: copy(200, 0), running: running) == nil)
    }

    /// A copy whose start time is unknown counts as the latest.
    @Test func aCopyWithoutAStartTimeCountsAsStartedLast() {
        #expect(SingleInstance.older(than: copy(100, nil), running: [copy(100, nil), copy(300, 5)]) == 300)
        #expect(SingleInstance.older(than: copy(300, 5), running: [copy(100, nil), copy(300, 5)]) == nil)
        #expect(SingleInstance.older(than: copy(300, nil), running: [copy(200, nil), copy(300, nil)]) == 200)
    }

    @Test func onlyMyselfMeansNoOther() {
        #expect(SingleInstance.older(than: copy(200, 0), running: [copy(200, 0), copy(100, nil, bundleID: "com.apple.finder")]) == nil)
        #expect(SingleInstance.older(than: copy(200, 0), running: []) == nil)
    }

    @Test func appsWithoutABundleIDAndOtherAppsAreIgnored() {
        let running = [copy(100, -5, bundleID: nil), copy(150, -5, bundleID: "io.github.other.relay"), copy(200, 0)]
        #expect(SingleInstance.older(than: copy(200, 0), running: running) == nil)
    }
}
