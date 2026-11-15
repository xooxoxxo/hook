import AppKit
import RelayCore
import SwiftUI
import Testing
@testable import RelayUIMac

@Suite @MainActor struct PhonePairingViewTests {
    @Test func pairingWindowReaderTracksItsActualHostAndDropsAStaleAttachment() async throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        var reported: NSWindow?
        var calls = 0
        let probe = PairingWindowReader.Probe { reported = $0; calls += 1 }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<10000 {
                if condition() { return }
                await Task.yield()
            }
            throw CancellationError()
        }
        first.contentView?.addSubview(probe)
        try await settle { reported === first }
        probe.removeFromSuperview()
        second.contentView?.addSubview(probe)
        try await settle { reported === second }
        probe.removeFromSuperview()
        try await settle { reported == nil }
        calls = 0
        first.contentView?.addSubview(probe)
        probe.removeFromSuperview()
        try await settle { calls > 0 }
        #expect(reported == nil)
    }

    @Test func placeholderSheetFitsTheApproved380PointWidthInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: PhonePairingView(host: "pond.example.test"))
            host.view.appearance = NSAppearance(named: appearance)
            let size = host.view.fittingSize
            #expect(size.width == 380)
            #expect(size.height > 400 && size.height < 700)
        }
    }

    @Test func saysPhoneNotIPhoneBecauseTheCodePairsAndroidToo() {
        #expect(PhonePairingView.title == "Pair a phone")
        #expect(PhonePairingView.pairButton == "Pair a phone…")
        for text in [PhonePairingView.title, PhonePairingView.pairButton, PhonePairingView.instruction,
                     PhonePairingView.copyHelp, PhonePairingView.privacyText] {
            #expect(!text.contains("iPhone"), "\(text)")
        }
    }

    @Test func explainsLoginPrivacyWithoutClaimingCredentialExpiry() {
        #expect(PhonePairingView.privacyText.contains("Pond login remains valid"))
        #expect(PhonePairingView.privacyText.contains("60 seconds"))
        #expect(PhonePairingView.privacyText.contains("own owner key"))
    }

    @Test func revokeConfirmationNamesTheDeviceAndWarnsForThisMacAndTheOnlyRecoveryKey() {
        let mac = OwnerKeyRow(id: "mac", label: "Studio", status: "approved", created: "")
        let phone = OwnerKeyRow(id: "phone", label: "iPhone", status: "approved", created: "")
        let only = OwnerStatus(required: true, keys: [mac], self_: OwnerSelf(id: "mac", status: "approved"))
        let message = OwnerKeyText.revokeMessage(mac, status: only)
        #expect(message.contains("Studio"))
        #expect(message.contains("this Mac's key"))
        #expect(message.contains("only approved recovery key"))
        let both = OwnerStatus(required: true, keys: [mac, phone], self_: only.self_)
        let otherMessage = OwnerKeyText.revokeMessage(phone, status: both)
        #expect(otherMessage.contains("iPhone"))
        #expect(!otherMessage.contains("this Mac's key") && !otherMessage.contains("only approved"))
    }
}
