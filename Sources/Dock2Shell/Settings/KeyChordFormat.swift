import AppKit
import Carbon.HIToolbox
import Dock2Core

extension KeyChord {
    /// The chord as macOS menus write it, ⌃⌥⇧⌘ then the key, the key named by the current keyboard layout.
    var displayName: String {
        var text = ""
        if modifiers & KeyChord.control != 0 { text += "⌃" }
        if modifiers & KeyChord.option != 0 { text += "⌥" }
        if modifiers & KeyChord.shift != 0 { text += "⇧" }
        if modifiers & KeyChord.command != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// Carbon's modifier bits for AppKit's flags.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= command }
        if flags.contains(.shift) { bits |= shift }
        if flags.contains(.option) { bits |= option }
        if flags.contains(.control) { bits |= control }
        return bits
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ code: UInt32) -> String {
        if let name = named[Int(code)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            UCKeyTranslate(pointer, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
