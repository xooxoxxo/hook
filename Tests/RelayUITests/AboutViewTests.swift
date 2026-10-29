import Foundation
import RelayCore
@testable import RelayUI
import Testing

@Suite @MainActor struct AboutViewTests {
    @Test func theVersionLineShowsTheBuildOnlyWhenItDiffers() {
        #expect(AboutView.versionLine(version: "0.9.3", build: "0.9.3") == "Version 0.9.3")
        #expect(AboutView.versionLine(version: "0.9.3", build: nil) == "Version 0.9.3")
        #expect(AboutView.versionLine(version: "0.9.3", build: "") == "Version 0.9.3")
        #expect(AboutView.versionLine(version: "0.9.3", build: "41") == "Version 0.9.3 (41)")
    }

    /// Support Hook shows only when the donation link is set (a valid https link).
    @Test func supportHookFollowsTheDonationLink() {
        #expect(AboutView(version: "0.9.3", onRunSetup: {}).supportURL == ConnectInfo.donationLink())
        #expect(AboutView(version: "0.9.3", supportURL: ConnectInfo.donationLink(""), onRunSetup: {}).supportURL == nil)
    }

    @Test func theProjectLinkIsTheGitHubRepo() {
        #expect(ConnectInfo.projectLink == URL(string: "https://github.com/xooxoxxo/hook"))
        #expect(ConnectInfo.projectLabel == "github.com/xooxoxxo/hook")
    }

    @Test func runSetupAgainCallsBack() {
        var ran = false
        AboutView(version: "0.9.3", onRunSetup: { ran = true }).onRunSetup()
        #expect(ran)
    }
}
