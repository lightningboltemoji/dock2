@testable import Dock2TOML
import Foundation
import Testing

// The grammar, ported from emira's `ConfigSyntaxTests` with its schema cases left behind.

@Suite struct TOMLGrammarTests {
    /// The error `text` produces, or nil if it parsed.
    static func diagnostic(_ text: String) -> TOMLError? {
        do {
            _ = try TOMLTable.parse(text)
            return nil
        } catch {
            return error as? TOMLError
        }
    }

    @Test func commentsAndBlanksAndTrailingCommentsAreIgnored() throws {
        let table = try TOMLTable.parse("""
        # heading comment
        [dock]   # after a header

        tile-size = 48   # points

        """)
        #expect(table.value(at: ["dock", "tile-size"])?.payload == .integer(48))
    }

    @Test func aHashInsideAStringIsNotAComment() throws {
        let table = try TOMLTable.parse("key = \"a # b\"\n")
        #expect(table.value(at: ["key"])?.payload == .string("a # b"))
    }

    @Test func quotedAndDottedKeysAreRead() throws {
        let table = try TOMLTable.parse("""
        [plugins."zip.tanner.dock2.bitwarden"]
        enabled = true
        tiles.player = false
        """)
        #expect(table.value(at: ["plugins", "zip.tanner.dock2.bitwarden", "enabled"])?.payload == .bool(true))
        #expect(table.value(at: ["plugins", "zip.tanner.dock2.bitwarden", "tiles", "player"])?.payload == .bool(false))
        #expect(table.tableNames(under: ["plugins"]) == ["zip.tanner.dock2.bitwarden"])
    }

    @Test func windowsLineEndingsAreNotASyntaxError() throws {
        let table = try TOMLTable.parse("[dock]\r\ntile-size = 48\r\n")
        #expect(table.value(at: ["dock", "tile-size"])?.asDouble == 48)
    }

    @Test func escapesInStringsAreRead() throws {
        let table = try TOMLTable.parse(#"key = "a\"b\\c\td""#)
        #expect(table.value(at: ["key"])?.payload == .string("a\"b\\c\td"))
    }

    @Test func anArrayMaySpanLinesAndCarryCommentsInside() throws {
        let table = try TOMLTable.parse("""
        pinned = [
            "com.apple.Safari",   # the browser
            "com.mitchellh.ghostty",
        ]
        """)
        #expect(table.value(at: ["pinned"])?.asArray?.compactMap(\.asString) == ["com.apple.Safari", "com.mitchellh.ghostty"])
    }

    @Test func arraysNest() throws {
        let table = try TOMLTable.parse("key = [[1, 2], [3]]\n")
        let numbers = table.value(at: ["key"])?.asArray?.map { $0.asArray?.compactMap(\.asDouble) ?? [] }
        #expect(numbers == [[1, 2], [3]])
    }

    @Test func multilineStringsAreRead() throws {
        let basic = try TOMLTable.parse("key = \"\"\"\nroses\nviolets\"\"\"\n")
        #expect(basic.value(at: ["key"])?.payload == .string("roses\nviolets"))
        let folded = try TOMLTable.parse("key = \"\"\"\\\n    one \\\n    two\\\n    \"\"\"\n")
        #expect(folded.value(at: ["key"])?.payload == .string("one two"))
        let literal = try TOMLTable.parse("key = '''\na\\d\nb'''\n")
        #expect(literal.value(at: ["key"])?.payload == .string("a\\d\nb"))
        let quoted = try TOMLTable.parse("key = \"\"\"a\"\"\"\"\n")
        #expect(quoted.value(at: ["key"])?.payload == .string("a\""))
    }

    @Test func everyEscapeTheSpecDefinesIsRead() throws {
        let table = try TOMLTable.parse(#"key = "\b\fé\U0001F600""#)
        #expect(table.value(at: ["key"])?.payload == .string("\u{08}\u{0C}é\u{1F600}"))
        #expect(Self.diagnostic("[dock]\n" + #"x = "\e""# + "\n")?.description == #"line 2: unknown escape '\e'"#)
        #expect(Self.diagnostic("[dock]\n" + #"x = "\u00g0""# + "\n")?.description
                == "line 2: an escape needs 4 hexadecimal digits")
        #expect(Self.diagnostic("[dock]\n" + #"x = "\ud800""# + "\n")?.description
                == #"line 2: '\ud800' is not a Unicode character"#)
    }

    @Test func theCharacterClassesAreTheSpecsAndNotSwifts() throws {
        let separator = try TOMLTable.parse("key = \"a\u{2028}b\"\n")
        #expect(separator.value(at: ["key"])?.payload == .string("a\u{2028}b"))
        #expect(Self.diagnostic("[dock]\ncafé = 8\n")?.description == "line 2: invalid key 'café'")
        #expect(Self.diagnostic("[dock]\ntile\u{2011}size = 8\n")?.description == "line 2: invalid key 'tile\u{2011}size'")
        #expect(Self.diagnostic("[dock]\ntile-size\u{00A0}=\u{00A0}8\n")?.description == "line 2: invalid key 'tile-size\u{00A0}'")
    }

    @Test func controlCharactersAreRefusedAndAByteOrderMarkIsNot() throws {
        #expect(Self.diagnostic("[dock]\nx = \"a\u{07}b\"\n")?.description
                == "line 2: a string cannot contain the control character U+0007")
        #expect(Self.diagnostic("[dock]\nx = 8 # \u{7F}\n")?.description
                == "line 2: a comment cannot contain the control character U+007F")
        let marked = try TOMLTable.parse("\u{FEFF}[dock]\ntile-size = 8\n")
        #expect(marked.value(at: ["dock", "tile-size"])?.asDouble == 8)
    }

    @Test func aLiteralStringIsAKeyToo() throws {
        let table = try TOMLTable.parse("[plugins]\n'zip.tanner.dock2.x' = 1\n")
        #expect(table.value(at: ["plugins", "zip.tanner.dock2.x"])?.payload == .integer(1))
    }

    @Test func everythingTheWriterSpellsTheReaderReadsBack() throws {
        let values: [TOMLValue] = [
            .string("plain"), .string("a \"b\" \\c"), .string("a\nb"), .string("a\tb"),
            .string("bell\u{07}here"), .string("del\u{7F}here"), .string("a\u{08}b"),
            .string("a\u{0C}b"), .string("\u{1F600}"), .literalString(#"^com\.apple\."#),
            .literalString("it's"), .literalString("ctrl\u{01}x"),
            .bool(true), .number(8), .number(-3), .number(0.5), .number(1e9),
            .array([.number(1), .string("x")]), .array([]),
        ]
        for value in values {
            let table = try TOMLTable.parse("k = " + value.spelled + "\n")
            #expect(table.value(at: ["k"])?.spelled == value.spelled, "\(value.spelled) did not round-trip")
        }
        for key in ["tile-size", "café", "π", "a b", "", "zip.tanner.dock2.x", "a\u{07}b"] {
            let table = try TOMLTable.parse(TOMLTable.spell(key: key) + " = 1\n")
            #expect(table.value(at: [key]) != nil, "\(TOMLTable.spell(key: key)) did not round-trip")
        }
    }

    @Test func theNumericGrammarIsTheSpecsAndNotSwifts() throws {
        let table = try TOMLTable.parse("a = 1_000\nb = 9_224.1\nc = 5e+22\n")
        #expect(table.value(at: ["a"])?.payload == .integer(1000))
        #expect(table.value(at: ["b"])?.payload == .float(9224.1))
        #expect(table.value(at: ["c"])?.payload == .float(5e22))
        for bad in [".5", "5.", "007", "1__0", "1_", "+.5", "1.e5", "0x1p3"] {
            #expect(Self.diagnostic("[dock]\nx = \(bad)\n")?.line == 2, "\(bad) should not parse")
        }
    }

    @Test func anInlineTableIsATable() throws {
        let table = try TOMLTable.parse("dock = { tile-size = 48, autohide = true }\n")
        #expect(table.value(at: ["dock", "tile-size"])?.asDouble == 48)
        #expect(table.value(at: ["dock", "autohide"])?.asBool == true)
    }

    @Test func inlineTablesNestAndCarryDottedKeys() throws {
        let table = try TOMLTable.parse("a = { b.c = 1, b.d = 2, e = { f = 3 } }\n")
        #expect(table.value(at: ["a", "b", "c"])?.payload == .integer(1))
        #expect(table.value(at: ["a", "b", "d"])?.payload == .integer(2))
        #expect(table.value(at: ["a", "e", "f"])?.payload == .integer(3))
    }

    @Test func anInlineTableIsClosed() {
        #expect(Self.diagnostic("[dock]\nx = { a = 1,\n b = 2 }\n")?.description
                == "line 2: unterminated inline table — it must open and close on one line")
        #expect(Self.diagnostic("[dock]\nx = { a = 1, }\n")?.line == 2)
        #expect(Self.diagnostic("a = { b = 1 }\n[a]\nc = 2\n")?.description == "line 2: 'a' is set twice")
        #expect(Self.diagnostic("a = { b = 1 }\na.c = 2\n")?.description == "line 2: 'a.c' is set twice")
    }

    @Test func radixIntegersAreRead() throws {
        let table = try TOMLTable.parse("a = 0xDEADBEEF\nb = 0o755\nc = 0b1010\n")
        #expect(table.value(at: ["a"])?.payload == .integer(0xDEADBEEF))
        #expect(table.value(at: ["b"])?.payload == .integer(0o755))
        #expect(table.value(at: ["c"])?.payload == .integer(0b1010))
        for bad in ["0x", "0xg", "0o8", "0b2", "-0x1", "+0x1", "0x1.5"] {
            #expect(Self.diagnostic("[dock]\nx = \(bad)\n")?.line == 2, "\(bad) should not parse")
        }
    }

    @Test func integersKeepEveryBitOfTheirRange() throws {
        let table = try TOMLTable.parse("a = 9223372036854775807\nb = -9223372036854775808\n")
        #expect(table.value(at: ["a"])?.payload == .integer(.max))
        #expect(table.value(at: ["b"])?.payload == .integer(.min))
        #expect(Self.diagnostic("[dock]\nx = 9223372036854775808\n")?.description
                == "line 2: '9223372036854775808' is too large for a 64-bit integer")
    }

    @Test func anIntegerAndAFloatAreNotTheSameValue() throws {
        let table = try TOMLTable.parse("a = 1\nb = 1.0\n")
        #expect(table.value(at: ["a"])?.spelled == "1")
        #expect(table.value(at: ["b"])?.spelled == "1.0")
        #expect(table.value(at: ["a"])?.asDouble == 1)
        #expect(table.value(at: ["b"])?.asDouble == 1)
    }

    @Test func dateTimesAreReadAndKeptAsWritten() throws {
        for text in ["1979-05-27T07:32:00Z", "1979-05-27T00:32:00-07:00", "1979-05-27", "07:32:00"] {
            let table = try TOMLTable.parse("a = \(text)\n")
            #expect(table.value(at: ["a"])?.spelled == text)
        }
        for bad in ["1979-02-30", "1979-13-01", "07:60:00"] {
            #expect(Self.diagnostic("[dock]\nx = \(bad)\n")?.description == "line 2: '\(bad)' is not a valid date or time")
        }
    }

    @Test func aSubtableAfterAnArrayOfTablesBelongsToItsLastElement() throws {
        let table = try TOMLTable.parse("""
        [[server]]
        ip = "1"
        [server.opts]
        fast = true
        [[server]]
        ip = "2"
        [server.opts]
        fast = false
        """)
        #expect(table.value(at: ["server", "ip"])?.payload == .string("2"))
        #expect(table.value(at: ["server", "opts", "fast"])?.payload == .bool(false))
    }

    @Test func redefiningATableIsRefused() {
        #expect(Self.diagnostic("[dock]\na = 1\n[dock]\nb = 2\n")?.description == "line 3: 'dock' is set twice")
        #expect(Self.diagnostic("dock = 1\n[dock]\n")?.description == "line 2: 'dock' is set twice")
        #expect(Self.diagnostic("[a]\nb.c = 1\n[a.b]\nd = 2\n")?.description == "line 3: 'a.b' is set twice")
        #expect(Self.diagnostic("[plugins.x.tiles]\na = 1\n[plugins.x]\nenabled = true\n") == nil)
    }

    @Test func aHeaderMayAddASubtableToADottedKeysTable() throws {
        let table = try TOMLTable.parse("[fruit]\napple.color = \"red\"\n\n[fruit.apple.texture]\nsmooth = true\n")
        #expect(table.value(at: ["fruit", "apple", "color"])?.payload == .string("red"))
        #expect(table.value(at: ["fruit", "apple", "texture", "smooth"])?.payload == .bool(true))
        #expect(Self.diagnostic("[fruit]\napple.color = \"red\"\n[fruit.apple]\n")?.description
                == "line 3: 'fruit.apple' is set twice")
    }

    @Test func malformedLinesAreSyntaxErrors() {
        #expect(Self.diagnostic("[dock\n")?.line == 1)
        #expect(Self.diagnostic("tile-size\n")?.description == "line 1: expected 'key = value'")
        #expect(Self.diagnostic("[dock]\ntile-size =\n")?.description == "line 2: missing value after '='")
        #expect(Self.diagnostic("[dock]\nx = \"unterminated\n")?.description == "line 2: unterminated string")
        #expect(Self.diagnostic("[dock]\nx = 'unterminated\n")?.description == "line 2: unterminated string")
        #expect(Self.diagnostic("[]\n")?.line == 1)
    }

    @Test func takingWhatIsKnownLeavesWhatIsNot() throws {
        var table = try TOMLTable.parse("""
        [dock]
        tile-size = 48
        tile-sise = 50

        [plugins."zip.x"]
        enabled = true

        [layuot]
        """)
        #expect(table.take(["dock", "tile-size"])?.asDouble == 48)
        table.acceptTable(["dock"])
        #expect(table.takeTable(["plugins"])?.value(at: ["zip.x", "enabled"])?.asBool == true)
        #expect(table.leftovers.map(\.key) == ["dock.tile-sise", "layuot"])
        #expect(table.leftovers.map(\.line) == [3, 8])
    }
}
