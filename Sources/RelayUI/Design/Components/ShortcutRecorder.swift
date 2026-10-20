import AppKit
import Carbon.HIToolbox
import RelayCore
import SwiftUI

/// The shortcut field on the General tab. Click it, then press a
/// combination with at least one of ⌘, ⌃ or ⌥; Esc or clicking elsewhere cancels.
public struct ShortcutRecorder: NSViewRepresentable {
    /// What the field shows while idle, e.g. "⌃⌥⌘R" or "(not set)".
    let label: String
    let onBegin: @MainActor () -> Void
    /// The pressed combination, or nil when it can't be a shortcut.
    let onRecord: @MainActor (HotkeySpec?) -> Void
    let onCancel: @MainActor () -> Void

    public init(label: String, onBegin: @escaping @MainActor () -> Void,
                onRecord: @escaping @MainActor (HotkeySpec?) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.label = label
        self.onBegin = onBegin
        self.onRecord = onRecord
        self.onCancel = onCancel
    }

    public func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        configure(button)
        return button
    }

    public func updateNSView(_ button: RecorderButton, context: Context) {
        configure(button)
    }

    private func configure(_ button: RecorderButton) {
        button.idleLabel = label
        button.onBegin = onBegin
        button.onRecord = onRecord
        button.onCancel = onCancel
        button.refreshTitle()
    }
}

/// A push button that catches the next key press while recording.
public final class RecorderButton: NSButton {
    var idleLabel = ""
    var onBegin: (@MainActor () -> Void)?
    var onRecord: (@MainActor (HotkeySpec?) -> Void)?
    var onCancel: (@MainActor () -> Void)?
    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: DS.Metric.recorderMin).isActive = true
        setAccessibilityLabel("Shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecorderButton is created in code")
    }

    public override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        title = isRecording ? "Press keys…" : idleLabel
    }

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        refreshTitle()
        onBegin?()
        window?.makeFirstResponder(self)
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        record(event)
    }

    /// ⌘ and ⌃ combinations arrive here before keyDown (and before the main menu).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        record(event)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    /// Closing Settings or switching apps mid-recording never resigns first
    /// responder, so watch the window too: either one cancels the recording and
    /// resumes the old shortcut.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        let center = NotificationCenter.default
        if let old = window {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
        }
        if let newWindow {
            center.addObserver(self, selector: #selector(windowEndsRecording(_:)),
                               name: NSWindow.didResignKeyNotification, object: newWindow)
            center.addObserver(self, selector: #selector(windowEndsRecording(_:)),
                               name: NSWindow.willCloseNotification, object: newWindow)
        } else {
            cancelRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowEndsRecording(_ note: Notification) {
        cancelRecording()
    }

    private func cancelRecording() {
        guard isRecording else { return }
        stop()
        onCancel?()
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
            stop()
            onCancel?()
            return
        }
        let spec = HotkeySpec.from(keyCode: UInt32(event.keyCode), carbonModifiers: Self.carbonModifiers(modifiers))
        stop()
        onRecord?(spec)
    }

    private func stop() {
        isRecording = false
        refreshTitle()
    }

    /// NSEvent flags → the Carbon mask RegisterEventHotKey uses.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}
