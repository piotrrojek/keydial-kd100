import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey via Carbon `RegisterEventHotKey`. Carbon hotkeys need
/// no Accessibility/TCC grant (unlike an `NSEvent` global monitor), and fire on the
/// main thread, so `onFire` can touch UI directly.
///
/// kd100 registers exactly one (⌥⌘K → toggle the cheat-sheet), so the handler doesn't
/// bother disambiguating by id; the instance pointer is threaded through `userData`.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onFire: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installErr = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onFire()
            return noErr
        }, 1, &spec, me, &eventHandler)
        guard installErr == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x6B643130), id: 1)   // 'kd10'
        let regErr = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regErr == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
