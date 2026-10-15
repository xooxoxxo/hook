import Carbon.HIToolbox
import Foundation
import RelayCore

/// One system-wide hotkey through Carbon `RegisterEventHotKey`.
/// Works from any app and needs no Accessibility permission.
/// `unregister()` removes the hotkey and its event handler; deinit does the same.
@MainActor final class GlobalHotKey {
    static let signature: OSType = 0x524C_4159   // 'RLAY'

    /// This registration's `EventHotKeyID.id`. Every registration gets a fresh one, so a
    /// handler ignores presses of another registration that is briefly alive beside it.
    let hotKeyID: UInt32
    private let action: @MainActor () -> Void
    // nonisolated(unsafe): deinit reads them; every other access is on the main actor.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?

    /// nil when the handler cannot be installed or the combination cannot be registered.
    init?(spec: HotkeySpec, id: UInt32, action: @escaping @MainActor () -> Void) {
        hotKeyID = id
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target events on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard pressedID.signature == GlobalHotKey.signature, pressedID.id == hotKey.hotKeyID else { return false }
                hotKey.action()
                return true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &pressed, me, &handlerRef)
        guard installed == noErr else { return nil }

        let registered = RegisterEventHotKey(
            spec.keyCode, spec.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            unregister()
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Safe to call more than once.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

/// The app's one global shortcut. A change registers the new combination
/// first and drops the old one only on success, so a failed change keeps the
/// shortcut that worked.
@MainActor final class HotKeyManager: ObservableObject {
    static let offLabel = "(not set)"

    /// "⌃⌥⌘R", or "(not set)" when the shortcut is off.
    @Published private(set) var label = HotKeyManager.offLabel {
        didSet { if label != oldValue { onLabelChange?() } }
    }
    /// After `label` changed (a change here, in the recorder, or a failed resume).
    var onLabelChange: (@MainActor () -> Void)?
    private let action: @MainActor () -> Void
    private var hotKey: GlobalHotKey?
    private var spec: HotkeySpec?
    private var suspended = false
    private var nextID: UInt32 = 0

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// "" turns the shortcut off. Returns false, keeping the current shortcut, when
    /// `raw` doesn't parse or Carbon refuses the combination.
    @discardableResult
    func apply(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            hotKey?.unregister()
            hotKey = nil
            spec = nil
            suspended = false
            label = Self.offLabel
            return true
        }
        guard let newSpec = HotkeySpec.parse(text) else { return false }
        if newSpec == spec {
            if suspended { resume() }
            return hotKey != nil
        }
        guard let registered = register(newSpec) else { return false }
        hotKey?.unregister()
        hotKey = registered
        spec = newSpec
        suspended = false
        label = newSpec.display
        return true
    }

    /// While the recorder listens, the current shortcut must not fire.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        hotKey?.unregister()
        hotKey = nil
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        guard let spec else { return }
        hotKey = register(spec)
        if hotKey == nil {
            self.spec = nil
            label = Self.offLabel
        }
    }

    private func register(_ spec: HotkeySpec) -> GlobalHotKey? {
        nextID &+= 1
        return GlobalHotKey(spec: spec, id: nextID, action: action)
    }
}
