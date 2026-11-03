import Testing
@testable import RelayCore

private func config(source: SourceKind? = nil, url: String? = nil, token: String? = nil,
                    context: String = RelayConfig.defaultContext) -> RelayConfig {
    RelayConfig(source: source, mailboxURL: url, tokenFile: token, context: context)
}

@Suite struct ProfilesTests {
    @Test func noPond() {
        let menu = ProfileMenu.make(config: config(source: .local))
        #expect(menu.profiles == [Profile(kind: .local, name: "This Mac", current: true)])
        #expect(menu.current?.name == "This Mac")
        #expect(menu.pondSaved == false)
        #expect(menu.readOnly == false)
    }

    @Test func pondWithTheDefaultContext() {
        let menu = ProfileMenu.make(config: config(source: .mailbox, url: "https://pond.example.com", token: "~/t"))
        #expect(menu.profiles == [Profile(kind: .local, name: "This Mac", current: false),
                                  Profile(kind: .mailbox, name: "Personal", current: true)])
        #expect(menu.current?.name == "Personal")
        #expect(menu.pondSaved)
    }

    /// A saved Pond stays listed while This Mac is the source, so the switch goes back to it.
    @Test func savedPondWhileOnThisMac() {
        let menu = ProfileMenu.make(config: config(source: .local, url: "https://pond.example.com", token: "~/t",
                                                   context: "work"))
        #expect(menu.profiles.map(\.name) == ["This Mac", "Work"])
        #expect(menu.current?.kind == .local)
    }

    @Test func customContextsInTitleCase() {
        #expect(ProfileMenu.name(context: "home-lab") == "Home Lab")
        #expect(ProfileMenu.name(context: "side_project two") == "Side Project Two")
        #expect(ProfileMenu.name(context: "  ") == "Pond")
        #expect(ProfileMenu.name(context: "ACME") == "ACME")
    }

    /// A URL without a token file isn't a saved Pond: Set Up a Pond… is offered instead.
    @Test func halfSavedPond() {
        let menu = ProfileMenu.make(config: config(source: .local, url: "https://pond.example.com", token: " "))
        #expect(menu.profiles.map(\.kind) == [.local])
        #expect(menu.pondSaved == false)
    }

    @Test func readOnly() {
        let menu = ProfileMenu.make(config: config(source: .local), readOnly: true)
        #expect(menu.readOnly)
        #expect(ProfileMenu.make(config: nil).readOnly)
        #expect(ProfileMenu.make(config: nil).current == nil)
        #expect(ProfileMenu.make(config: nil).label == "No Queue")
    }

    @Test func spokenLabel() {
        let menu = ProfileMenu.make(config: config(source: .mailbox, url: "https://pond.example.com", token: "~/t"))
        let status = PanelStatus.make(StatusInputs(sourceKey: "mailbox:m#p", reachable: true, loadedOnce: true))
        #expect(ProfileMenu.accessibilityText(menu, status: status) == "Profile Personal. Status: Pond, ready")
    }
}
