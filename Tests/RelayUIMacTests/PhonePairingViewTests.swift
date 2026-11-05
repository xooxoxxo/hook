import AppKit
import RelayCore
import SwiftUI
import Testing
@testable import RelayUIMac

@Suite @MainActor struct PhonePairingViewTests {
    @Test func placeholderSheetFitsTheApproved380PointWidthInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: PhonePairingView(host: "pond.example.test"))
            host.view.appearance = NSAppearance(named: appearance)
            let size = host.view.fittingSize
            #expect(size.width == 380)
            #expect(size.height > 400 && size.height < 700)
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
