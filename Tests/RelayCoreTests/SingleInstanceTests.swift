import Testing
@testable import RelayCore

private let relay = "io.github.xooxoxxo.relay"

@Suite struct SingleInstanceTests {
    @Test func anotherRelayIsFound() {
        let running: [(bundleID: String?, pid: Int32)] = [("com.apple.finder", 100), (relay, 200), (relay, 300)]
        #expect(SingleInstance.other(bundleID: relay, myPID: 200, running: running) == 300)
        #expect(SingleInstance.other(bundleID: relay, myPID: 300, running: running) == 200)
    }

    @Test func onlyMyselfMeansNoOther() {
        #expect(SingleInstance.other(bundleID: relay, myPID: 200, running: [(relay, 200), ("com.apple.finder", 100)]) == nil)
        #expect(SingleInstance.other(bundleID: relay, myPID: 200, running: []) == nil)
    }

    @Test func appsWithoutABundleIDAndOtherAppsAreIgnored() {
        #expect(SingleInstance.other(bundleID: relay, myPID: 200, running: [(nil, 300), ("io.github.other.relay", 400)]) == nil)
    }
}
