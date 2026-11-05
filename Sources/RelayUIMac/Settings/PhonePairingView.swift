import AppKit
import RelayMacCore
import RelayUI
import SwiftUI

/// Stock sheet content. Gallery callers supply no image: the placeholder holds no setup data.
public struct PhonePairingView: View {
    private let image: NSImage?
    private let host: String
    private let onCopy: () -> Void
    private let onClose: () -> Void

    public init(image: NSImage? = nil, host: String, onCopy: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}) {
        self.image = image
        self.host = host
        self.onCopy = onCopy
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Pair an iPhone").font(.title2.bold())
            Text("Open Hook on your iPhone and scan this code.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let image {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .accessibilityLabel("Private Pond setup code")
                } else {
                    // A symbol, never an encoded credential or a stored QR fixture.
                    Image(systemName: "qrcode").resizable().scaledToFit()
                        .foregroundStyle(.gray)
                        .accessibilityLabel("Setup code placeholder")
                }
            }
            .padding(DS.Space.section)
            .frame(width: 240, height: 240)
            .background(.white)
            Text(verbatim: host).font(.headline).lineLimit(2)
                .textSelection(.enabled)
            Text(Self.privacyText)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Setup Code", action: onCopy)
                .help("Copies the Pond login so you can paste it into Hook on your iPhone.")
            Button("Done", action: onClose).keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.section)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    public static let privacyText = "This code contains your Pond login. Keep it private. It hides after 60 seconds; the Pond login remains valid. Your iPhone creates its own owner key."
}

@MainActor struct PhonePairingRow: View {
    @ObservedObject var controller: PhonePairingController
    @State private var presented = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(controller.authenticating ? "Authenticating…" : "Pair an iPhone…") {
                problem = nil
                Task {
                    do {
                        try await controller.show()
                        presented = controller.image != nil
                    } catch PhonePairingController.Failure.cancelled {
                        // Closing or cancelling authentication has no error to resolve.
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
            .disabled(!controller.available || controller.authenticating)
            if let problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $presented, onDismiss: controller.hide) {
            PhonePairingSheet(controller: controller, onClose: { presented = false; controller.hide() })
        }
        .onChange(of: controller.image == nil) { _, hidden in if hidden { presented = false } }
        .onDisappear { controller.hide() }
    }
}

/// Observe the controller inside the sheet too, so clearing removes the image during dismissal.
@MainActor private struct PhonePairingSheet: View {
    @ObservedObject var controller: PhonePairingController
    let onClose: () -> Void

    var body: some View {
        Group {
            if let image = controller.image, let host = controller.host {
                PhonePairingView(image: image, host: host, onCopy: controller.copySetupCode, onClose: onClose)
            } else {
                Color(nsColor: .windowBackgroundColor).frame(width: 380, height: 500)
            }
        }
    }
}
