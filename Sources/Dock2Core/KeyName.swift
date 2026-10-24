/// The keys a shortcut can name in the config file, from emira's vocabulary: a physical key position by its
/// US-layout name. Punctuation is named (`period`), since `-` separates a chord's words.
public enum KeyName: String, Sendable, CaseIterable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20
    case left, right, up, down
    /// `backspace` is the key a Mac labels "delete"; `delete` is ⌦.
    case enter, tab, space, escape, backspace, delete
    case home, end, pageup, pagedown
    case minus, equal, leftbracket, rightbracket, backslash
    case semicolon, quote, comma, period, slash, backtick

    /// Carbon's virtual key code: `kVK_ANSI_…` and `kVK_…`, which `KeyNameTests` checks entry by entry.
    public var keyCode: UInt32 {
        switch self {
        case .a: 0x00
        case .b: 0x0B
        case .c: 0x08
        case .d: 0x02
        case .e: 0x0E
        case .f: 0x03
        case .g: 0x05
        case .h: 0x04
        case .i: 0x22
        case .j: 0x26
        case .k: 0x28
        case .l: 0x25
        case .m: 0x2E
        case .n: 0x2D
        case .o: 0x1F
        case .p: 0x23
        case .q: 0x0C
        case .r: 0x0F
        case .s: 0x01
        case .t: 0x11
        case .u: 0x20
        case .v: 0x09
        case .w: 0x0D
        case .x: 0x07
        case .y: 0x10
        case .z: 0x06
        case .digit0: 0x1D
        case .digit1: 0x12
        case .digit2: 0x13
        case .digit3: 0x14
        case .digit4: 0x15
        case .digit5: 0x17
        case .digit6: 0x16
        case .digit7: 0x1A
        case .digit8: 0x1C
        case .digit9: 0x19
        case .f1: 0x7A
        case .f2: 0x78
        case .f3: 0x63
        case .f4: 0x76
        case .f5: 0x60
        case .f6: 0x61
        case .f7: 0x62
        case .f8: 0x64
        case .f9: 0x65
        case .f10: 0x6D
        case .f11: 0x67
        case .f12: 0x6F
        case .f13: 0x69
        case .f14: 0x6B
        case .f15: 0x71
        case .f16: 0x6A
        case .f17: 0x40
        case .f18: 0x4F
        case .f19: 0x50
        case .f20: 0x5A
        case .left: 0x7B
        case .right: 0x7C
        case .up: 0x7E
        case .down: 0x7D
        case .enter: 0x24
        case .tab: 0x30
        case .space: 0x31
        case .escape: 0x35
        case .backspace: 0x33
        case .delete: 0x75
        case .home: 0x73
        case .end: 0x77
        case .pageup: 0x74
        case .pagedown: 0x79
        case .minus: 0x1B
        case .equal: 0x18
        case .leftbracket: 0x21
        case .rightbracket: 0x1E
        case .backslash: 0x2A
        case .semicolon: 0x29
        case .quote: 0x27
        case .comma: 0x2B
        case .period: 0x2F
        case .slash: 0x2C
        case .backtick: 0x32
        }
    }

    /// The key at a virtual key code, or nil for one this vocabulary has no name for.
    public init?(keyCode: UInt32) {
        guard let key = Self.byCode[keyCode] else { return nil }
        self = key
    }

    private static let byCode: [UInt32: KeyName] = Dictionary(allCases.map { ($0.keyCode, $0) }, uniquingKeysWith: { first, _ in first })

    /// The name of the key a punctuation character sits on, for the complaint about `cmd-.`.
    static func name(forCharacter character: String) -> String? {
        let names: [String: KeyName] = ["=": .equal, "[": .leftbracket, "]": .rightbracket, "\\": .backslash, ";": .semicolon,
                                        "'": .quote, ",": .comma, ".": .period, "/": .slash, "`": .backtick]
        return names[character]?.rawValue
    }
}

extension KeyChord {
    /// Each modifier's words, the first the one written: ⌃⌥⇧⌘, macOS's order.
    private static let modifierWords: [(bit: UInt32, words: [String])] = [
        (control, ["ctrl", "control"]), (option, ["alt", "opt", "option"]), (shift, ["shift"]), (command, ["cmd", "command"]),
    ]

    /// `"ctrl-alt-space"`: the modifiers in ⌃⌥⇧⌘ order, then the key. Nil for a key with no name.
    public var spelled: String? {
        guard let key = KeyName(keyCode: keyCode) else { return nil }
        let words = Self.modifierWords.filter { modifiers & $0.bit != 0 }.map(\.words[0])
        return (words + [key.rawValue]).joined(separator: "-")
    }

    /// Reads a chord as `spelled` writes it, modifiers in any order and by any of their words.
    public init(spelling text: String) throws(SettingProblem) {
        guard !text.isEmpty else { throw SettingProblem("names no key") }
        var modifiers: UInt32 = 0
        var key: KeyName?
        for word in text.split(separator: "-", omittingEmptySubsequences: false).map(String.init) {
            guard !word.isEmpty else { throw SettingProblem("has a '-' with nothing beside it; the minus key is spelled 'minus'") }
            if let bit = Self.modifierWords.first(where: { $0.words.contains(word) })?.bit {
                guard modifiers & bit == 0 else { throw SettingProblem("names '\(word)' twice") }
                modifiers |= bit
            } else if let named = KeyName(rawValue: word) {
                guard key == nil else { throw SettingProblem("names two keys; a shortcut takes one") }
                key = named
            } else if let name = KeyName.name(forCharacter: word) {
                throw SettingProblem("spells the '\(word)' key as itself; it is '\(name)'")
            } else {
                throw SettingProblem("names an unknown key or modifier '\(word)'")
            }
        }
        guard let key else { throw SettingProblem("names only modifiers; it needs a key too") }
        self.init(keyCode: key.keyCode, modifiers: modifiers)
    }
}
