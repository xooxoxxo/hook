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
            Text(Self.title).font(.title2.bold())
            Text(Self.instruction)
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
                .help(Self.copyHelp)
            Button("Done", action: onClose).keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.section)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    public static let title = "Pair a phone"
    /// The Settings › Queue › Owner Key button that opens this sheet.
    public static let pairButton = "Pair a phone…"
    public static let instruction = "Open Hook on your phone and scan this code."
    public static let copyHelp = "Copies the Pond login so you can paste it into Hook on your phone."
    public static let privacyText = "This code contains your Pond login. Keep it private. It hides after 60 seconds; the Pond login remains valid. Your phone creates its own owner key."
}

@MainActor struct PhonePairingRow: View {
    @ObservedObject var controller: PhonePairingController
    @State private var presented = false
    @State private var problem: String?
    @State private var presentationWindow = PairingWindowReference()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(controller.authenticating ? "Authenticating…" : PhonePairingView.pairButton) {
                guard let window = presentationWindow.window else { return }
                problem = nil
                Task {
                    do {
                        try await controller.show(in: window)
                        presented = controller.image != nil
                    } catch PhonePairingController.Failure.cancelled {
                        // Closing or cancelling authentication has no error to resolve.
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
            .disabled(!controller.available || controller.authenticating || presentationWindow.window == nil)
            if let problem {
                Text(verbatim: problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(PairingWindowReader { window in
            if presentationWindow.window !== window { controller.hide() }
            presentationWindow = PairingWindowReference(window: window)
        }.frame(width: 0, height: 0))
        .sheet(isPresented: $presented, onDismiss: controller.hide) {
            PhonePairingSheet(controller: controller, onClose: { presented = false; controller.hide() })
        }
        .onChange(of: controller.image == nil) { _, hidden in if hidden { presented = false } }
        .onDisappear { controller.hide() }
    }
}

/// Hold the presenting window weakly so the row cannot keep a closed window alive.
private struct PairingWindowReference {
    weak var window: NSWindow?
}

struct PairingWindowReader: NSViewRepresentable {
    let changed: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> Probe { Probe(changed: changed) }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        private let changed: @MainActor (NSWindow?) -> Void
        init(changed: @escaping @MainActor (NSWindow?) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("No storyboard") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Report after AppKit's attachment transaction, using the current
            // window so a queued old attachment cannot revive a detached host.
            Task { @MainActor [weak self] in
                guard let self else { return }
                changed(window)
            }
        }
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
