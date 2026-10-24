import Carbon.HIToolbox
import Dock2Core
import Testing

@Suite struct HotKeysTests {
    /// A chord is handed to `RegisterEventHotKey` as it is, so its bits must be Carbon's.
    @Test func aChordsModifiersAreCarbons() {
        #expect(KeyChord.command == UInt32(cmdKey))
        #expect(KeyChord.shift == UInt32(shiftKey))
        #expect(KeyChord.option == UInt32(optionKey))
        #expect(KeyChord.control == UInt32(controlKey))
    }
}

@Suite struct KeyNameTests {
    /// The config file's key names, each at Carbon's code for it.
    @Test func everyNameIsAtCarbonsCode() {
        let carbon: [KeyName: Int] = [
            .a: kVK_ANSI_A, .b: kVK_ANSI_B, .c: kVK_ANSI_C, .d: kVK_ANSI_D, .e: kVK_ANSI_E, .f: kVK_ANSI_F, .g: kVK_ANSI_G,
            .h: kVK_ANSI_H, .i: kVK_ANSI_I, .j: kVK_ANSI_J, .k: kVK_ANSI_K, .l: kVK_ANSI_L, .m: kVK_ANSI_M, .n: kVK_ANSI_N,
            .o: kVK_ANSI_O, .p: kVK_ANSI_P, .q: kVK_ANSI_Q, .r: kVK_ANSI_R, .s: kVK_ANSI_S, .t: kVK_ANSI_T, .u: kVK_ANSI_U,
            .v: kVK_ANSI_V, .w: kVK_ANSI_W, .x: kVK_ANSI_X, .y: kVK_ANSI_Y, .z: kVK_ANSI_Z,
            .digit0: kVK_ANSI_0, .digit1: kVK_ANSI_1, .digit2: kVK_ANSI_2, .digit3: kVK_ANSI_3, .digit4: kVK_ANSI_4,
            .digit5: kVK_ANSI_5, .digit6: kVK_ANSI_6, .digit7: kVK_ANSI_7, .digit8: kVK_ANSI_8, .digit9: kVK_ANSI_9,
            .f1: kVK_F1, .f2: kVK_F2, .f3: kVK_F3, .f4: kVK_F4, .f5: kVK_F5, .f6: kVK_F6, .f7: kVK_F7, .f8: kVK_F8, .f9: kVK_F9,
            .f10: kVK_F10, .f11: kVK_F11, .f12: kVK_F12, .f13: kVK_F13, .f14: kVK_F14, .f15: kVK_F15, .f16: kVK_F16,
            .f17: kVK_F17, .f18: kVK_F18, .f19: kVK_F19, .f20: kVK_F20,
            .left: kVK_LeftArrow, .right: kVK_RightArrow, .up: kVK_UpArrow, .down: kVK_DownArrow,
            .enter: kVK_Return, .tab: kVK_Tab, .space: kVK_Space, .escape: kVK_Escape, .backspace: kVK_Delete,
            .delete: kVK_ForwardDelete, .home: kVK_Home, .end: kVK_End, .pageup: kVK_PageUp, .pagedown: kVK_PageDown,
            .minus: kVK_ANSI_Minus, .equal: kVK_ANSI_Equal, .leftbracket: kVK_ANSI_LeftBracket,
            .rightbracket: kVK_ANSI_RightBracket, .backslash: kVK_ANSI_Backslash, .semicolon: kVK_ANSI_Semicolon,
            .quote: kVK_ANSI_Quote, .comma: kVK_ANSI_Comma, .period: kVK_ANSI_Period, .slash: kVK_ANSI_Slash,
            .backtick: kVK_ANSI_Grave,
        ]
        #expect(carbon.count == KeyName.allCases.count)
        for key in KeyName.allCases {
            #expect(key.keyCode == UInt32(carbon[key] ?? -1), "\(key)")
            #expect(KeyName(keyCode: key.keyCode) == key)
        }
    }
}
