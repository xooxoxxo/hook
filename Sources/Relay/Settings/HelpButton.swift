import AppKit
import SwiftUI

/// The native "?" button. A click shows `text` in a popover, so explanations stay
/// out of sight until asked for.
struct HelpButton: NSViewRepresentable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.bezelStyle = .helpButton
        button.setAccessibilityLabel("Help")
        context.coordinator.text = text
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.text = text
    }

    @MainActor final class Coordinator: NSObject {
        var text = ""
        private var popover: NSPopover?

        @objc func toggle(_ sender: NSButton) {
            if let popover, popover.isShown {
                popover.performClose(sender)
                return
            }
            let content = NSHostingController(rootView:
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12))
            content.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = content
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}
