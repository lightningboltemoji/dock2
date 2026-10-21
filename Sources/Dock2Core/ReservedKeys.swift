/// The ⌘ chords dock2 and Files give meaning to ([keyboard](product/keyboard.md)), by Carbon key code: what a
/// global shortcut set on one of them takes away, which Settings says when it is set.
public enum ReservedKeys {
    private static let c = KeyChord.command, s = KeyChord.shift, o = KeyChord.option

    /// Key codes, from Carbon's `kVK_ANSI_…` and `kVK_…`.
    private enum Key {
        static let a: UInt32 = 0, d: UInt32 = 2, f: UInt32 = 3, h: UInt32 = 4, z: UInt32 = 6, cKey: UInt32 = 8, v: UInt32 = 9
        static let w: UInt32 = 13, e: UInt32 = 14, t: UInt32 = 17, o: UInt32 = 31, l: UInt32 = 37, k: UInt32 = 40
        static let comma: UInt32 = 43, n: UInt32 = 45, period: UInt32 = 47, delete: UInt32 = 51, g: UInt32 = 5
        static let digits: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    private static let table: [(KeyChord, String)] = {
        var table: [(KeyChord, String)] = [
            (KeyChord(keyCode: Key.k, modifiers: c), "dock2's actions (⌘K)"),
            (KeyChord(keyCode: Key.comma, modifiers: c), "dock2's Settings (⌘,)"),
            (KeyChord(keyCode: Key.w, modifiers: c), "dismissing dock2 (⌘W)"),
            (KeyChord(keyCode: Key.cKey, modifiers: c), "copying in Files (⌘C)"),
            (KeyChord(keyCode: Key.v, modifiers: c), "pasting in Files (⌘V)"),
            (KeyChord(keyCode: Key.v, modifiers: c | s), "moving here in Files (⇧⌘V)"),
            (KeyChord(keyCode: Key.v, modifiers: c | o), "moving here in Files (⌥⌘V)"),
            (KeyChord(keyCode: Key.d, modifiers: c), "duplicating in Files (⌘D)"),
            (KeyChord(keyCode: Key.n, modifiers: c | s), "a new folder in Files (⇧⌘N)"),
            (KeyChord(keyCode: Key.delete, modifiers: c), "moving to the Trash in Files (⌘⌫)"),
            (KeyChord(keyCode: Key.delete, modifiers: c | o), "deleting in Files (⌥⌘⌫)"),
            (KeyChord(keyCode: Key.z, modifiers: c), "undo in Files (⌘Z)"),
            (KeyChord(keyCode: Key.z, modifiers: c | s), "redo in Files (⇧⌘Z)"),
            (KeyChord(keyCode: Key.t, modifiers: c), "Files' other tab (⌘T)"),
            (KeyChord(keyCode: Key.f, modifiers: c), "searching a folder in Files (⌘F)"),
            (KeyChord(keyCode: Key.g, modifiers: c | s), "typing a path in Files (⇧⌘G)"),
            (KeyChord(keyCode: Key.h, modifiers: c | s), "Home in Files (⇧⌘H)"),
            (KeyChord(keyCode: Key.d, modifiers: c | s), "Desktop in Files (⇧⌘D)"),
            (KeyChord(keyCode: Key.o, modifiers: c | s), "Documents in Files (⇧⌘O)"),
            (KeyChord(keyCode: Key.l, modifiers: c | o), "Downloads in Files (⌥⌘L)"),
            (KeyChord(keyCode: Key.a, modifiers: c | s), "Applications in Files (⇧⌘A)"),
            (KeyChord(keyCode: Key.period, modifiers: c | s), "showing hidden files in Files (⇧⌘.)"),
            (KeyChord(keyCode: Key.e, modifiers: c), "ejecting in Files (⌘E)"),
            (KeyChord(keyCode: Key.period, modifiers: c), "cancelling in Files (⌘.)"),
        ]
        for (index, code) in Key.digits.enumerated() {
            table.append((KeyChord(keyCode: code, modifiers: c), "opening tile \(index + 1) (⌘\(index + 1))"))
        }
        return table
    }()

    /// What a global shortcut on `chord` would take from dock2 itself, if anything: "pasting in Files (⌘V)".
    public static func taken(by chord: KeyChord) -> String? {
        table.first { $0.0 == chord }?.1
    }
}
