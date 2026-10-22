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
