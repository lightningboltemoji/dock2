import Carbon.HIToolbox
import Dock2Core
import Foundation

/// Global shortcuts through Carbon's hot keys: no permission, and the chord is taken from every app while it
/// is registered.
@MainActor
public final class HotKeys {
    /// Keeps a registration; dropping it unregisters the chord.
    @MainActor
    public final class Registration {
        fileprivate let reference: EventHotKeyRef
        fileprivate let id: UInt32

        fileprivate init(reference: EventHotKeyRef, id: UInt32) {
            self.reference = reference
            self.id = id
        }

        isolated deinit {
            UnregisterEventHotKey(reference)
            HotKeys.handlers[id] = nil
        }
    }

    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false
    /// 'dck2', as Carbon tells hot keys apart.
    private static let signature: OSType = 0x6463_6B32

    /// Registers `chord`; `handler` runs on the main actor each time it is pressed. Nil when the chord could
    /// not be registered — the system or another app already holds it.
    public static func register(_ chord: KeyChord, _ handler: @escaping @MainActor () -> Void) -> Registration? {
        installHandler()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            warn("could not register the shortcut (key \(chord.keyCode), modifiers \(chord.modifiers)): error \(status)")
            return nil
        }
        handlers[id] = handler
        return Registration(reference: reference, id: id)
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { HotKeys.handlers[id.id]?() }
            return noErr
        }, 1, &type, nil, nil)
    }
}
