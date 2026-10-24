@testable import Dock2TOML
import Foundation
import Testing

// Text ⇄ edits, ported from emira's `ConfigDocumentTests`. A document read and written back is the same
// bytes, and an edit moves only the line it is about.

@Suite struct TOMLDocumentTests {
    struct File: Sendable, CustomStringConvertible {
        let name: String
        let text: String
        var description: String { name }
    }

    static let real = #"""
    # dock2, as I like it

    [general]
    summon = "cmd-space"

    [dock]
    tile-size = 56
    autohide = true   # the screen is small
    pinned = [
        "com.apple.Safari",
        "com.mitchellh.ghostty",
    ]

    [search]
    excluded-folders = ["~/Library"]

    [plugins."zip.tanner.dock2.bitwarden"]
    enabled = true
    revoked = ["query"]

    [plugins."zip.tanner.dock2.bitwarden".settings]
    server = "https://vault.bitwarden.eu"

    """#

    static let crlf = "[dock]\r\ntile-size = 56\r\nautohide = true\r\n\r\n[files]\r\nfolders-first = false\r\n"
    static let noTrailingNewline = "[dock]\ntile-size = 56\nautohide = true"
    static let trailingComments = """
    # how the dock sits
    [dock]      # points throughout
    tile-size = 56    # a little larger
    autohide = true    # the screen is small
    bounce-on-launch = false
    """

    static let corpus: [File] = [
        File(name: "a real file", text: real),
        File(name: "CRLF", text: crlf),
        File(name: "no trailing newline", text: noTrailingNewline),
        File(name: "trailing comments", text: trailingComments),
        File(name: "empty", text: ""),
        File(name: "nothing but a comment", text: "# not a setting in sight\n"),
    ]

    static func changedLines(_ before: String, _ after: String) -> [String] {
        let old = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let new = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard old.count == new.count else { return ["\(old.count) lines became \(new.count)"] }
        return zip(old, new).filter { $0 != $1 }.map { String($1) }
    }

    @Test(arguments: corpus)
    func aDocumentRendersBackByteForByte(_ file: File) throws {
        #expect(try TOMLDocument(file.text).rendered == file.text)
    }

    @Test func settingAValueTheFileAlreadyHasMovesExactlyOneLine() throws {
        var document = try TOMLDocument(Self.real)
        try document.set(["dock", "tile-size"], to: .number(64))
        #expect(Self.changedLines(Self.real, document.rendered) == ["tile-size = 64"])
        #expect(document.table.value(at: ["dock", "tile-size"])?.asDouble == 64)
    }

    @Test func aValueKeepsItsTrailingComment() throws {
        var document = try TOMLDocument(Self.real)
        try document.set(["dock", "autohide"], to: .bool(false))
        #expect(Self.changedLines(Self.real, document.rendered) == ["autohide = false   # the screen is small"])
    }

    @Test func aMultilineValueIsReplacedWhole() throws {
        var document = try TOMLDocument(Self.real)
        try document.set(["dock", "pinned"], to: .array([.string("com.apple.Safari")]))
        #expect(document.rendered.contains("autohide = true   # the screen is small\npinned = [\"com.apple.Safari\"]\n\n[search]"))
    }

    @Test func aNewKeyJoinsTheEndOfItsTablesRunOfKeys() throws {
        var document = try TOMLDocument(Self.real)
        try document.set(["general", "onboarded"], to: .bool(true))
        #expect(document.rendered.contains("summon = \"cmd-space\"\nonboarded = true\n\n[dock]"))
    }

    @Test func aNewKeyGoesBeforeTheCommentThatIntroducesTheNextTable() throws {
        var document = try TOMLDocument("[dock]\ntile-size = 56\n\n# the field\n[search]\nfield-form = \"gem\"\n")
        try document.set(["dock", "autohide"], to: .bool(true))
        #expect(document.rendered == "[dock]\ntile-size = 56\nautohide = true\n\n# the field\n[search]\nfield-form = \"gem\"\n")
    }

    @Test func aKeyWhoseTableHasNoHeaderGetsOne() throws {
        var document = try TOMLDocument("[dock]\ntile-size = 56\n")
        try document.set(["clipboard", "history"], to: .bool(true))
        #expect(document.rendered == "[dock]\ntile-size = 56\n\n[clipboard]\nhistory = true\n")
    }

    @Test func aKeyInAnEmptyTableGoesRightUnderItsHeader() throws {
        var document = try TOMLDocument("[files]\n\n[dock]\ntile-size = 56\n")
        try document.set(["files", "show-hidden"], to: .bool(true))
        #expect(document.rendered == "[files]\nshow-hidden = true\n\n[dock]\ntile-size = 56\n")
    }

    @Test func anEmptyFileBecomesJustTheTableAndTheKey() throws {
        var document = try TOMLDocument("")
        try document.set(["dock", "tile-size"], to: .number(56))
        #expect(document.rendered == "[dock]\ntile-size = 56\n")
    }

    @Test func aCRLFFileKeepsItsLineEndingsThroughAnEdit() throws {
        var document = try TOMLDocument(Self.crlf)
        try document.set(["dock", "tile-size"], to: .number(64))
        try document.set(["dock", "bounce-on-launch"], to: .bool(false))
        #expect(document.rendered == "[dock]\r\ntile-size = 64\r\nautohide = true\r\nbounce-on-launch = false\r\n\r\n"
                                   + "[files]\r\nfolders-first = false\r\n")
    }

    @Test func theSameChangeWrittenTwiceWritesTheSameFile() throws {
        var once = try TOMLDocument(Self.real)
        try once.set(["files", "show-hidden"], to: .bool(true))
        var again = try TOMLDocument(once.rendered)
        try again.set(["files", "show-hidden"], to: .bool(true))
        #expect(again.rendered == once.rendered)
    }

    @Test func removingAKeyTheFileDoesNotSetIsANoOp() throws {
        var document = try TOMLDocument(Self.real)
        try document.remove(["dock", "bounce-on-launch"])
        #expect(document.rendered == Self.real)
    }

    @Test func removingAKeyTakesItsTrailingCommentAndLeavesNoBlankLine() throws {
        var document = try TOMLDocument(Self.trailingComments)
        try document.remove(["dock", "autohide"])
        #expect(document.rendered == """
        # how the dock sits
        [dock]      # points throughout
        tile-size = 56    # a little larger
        bounce-on-launch = false
        """)
    }

    @Test func removingAMultilineValueTakesEveryLineOfIt() throws {
        var document = try TOMLDocument(Self.real)
        try document.remove(["dock", "pinned"])
        #expect(document.rendered.contains("autohide = true   # the screen is small\n\n[search]"))
    }

    @Test func removingTheLastLineOfAFileThatDoesNotEndInATerminator() throws {
        var document = try TOMLDocument(Self.noTrailingNewline)
        try document.remove(["dock", "autohide"])
        #expect(document.rendered == "[dock]\ntile-size = 56")
    }

    // Plugin ids carry dots, so they are quoted segments.

    @Test func aPluginsKeyIsEditedUnderItsQuotedHeader() throws {
        var document = try TOMLDocument(Self.real)
        try document.set(["plugins", "zip.tanner.dock2.bitwarden", "settings", "server"], to: .string("https://example.com"))
        #expect(Self.changedLines(Self.real, document.rendered) == [#"server = "https://example.com""#])
    }

    @Test func aNewPluginGetsAQuotedHeader() throws {
        var document = try TOMLDocument("[dock]\ntile-size = 56\n")
        try document.set(["plugins", "zip.tanner.dock2.now-playing", "enabled"], to: .bool(true))
        #expect(document.rendered == "[dock]\ntile-size = 56\n\n[plugins.\"zip.tanner.dock2.now-playing\"]\nenabled = true\n")
    }

    @Test func aSubtableOfAWrittenTableJoinsItsRunAsADottedKey() throws {
        var document = try TOMLDocument(Self.real)
        try document.set(["plugins", "zip.tanner.dock2.bitwarden", "tiles", "vault"], to: .bool(false))
        #expect(document.rendered.contains("revoked = [\"query\"]\ntiles.vault = false\n\n[plugins.\"zip.tanner.dock2.bitwarden\".settings]"))
        #expect(document.table.value(at: ["plugins", "zip.tanner.dock2.bitwarden", "tiles", "vault"])?.asBool == false)
    }

    @Test func aKeyBesideDottedKeysJoinsThem() throws {
        var document = try TOMLDocument("[plugins]\n\"zip.x\".enabled = true\n")
        try document.set(["plugins", "zip.x", "results"], to: .bool(false))
        #expect(document.rendered == "[plugins]\n\"zip.x\".enabled = true\n\"zip.x\".results = false\n")
    }

    @Test func aTableImpliedByADeeperHeaderIsDeclared() throws {
        var document = try TOMLDocument("[plugins.\"zip.x\".settings]\nserver = \"a\"\n")
        try document.set(["plugins", "zip.x", "enabled"], to: .bool(true))
        #expect(document.rendered == "[plugins.\"zip.x\".settings]\nserver = \"a\"\n\n[plugins.\"zip.x\"]\nenabled = true\n")
    }

    @Test func anInlineTableIsChangedInPlaceButNotAddedTo() throws {
        var document = try TOMLDocument("[plugins.\"zip.x\"]\ntiles = { player = false }\n")
        try document.set(["plugins", "zip.x", "tiles", "player"], to: .bool(true))
        #expect(document.rendered == "[plugins.\"zip.x\"]\ntiles = { player = true }\n")
        let before = document.rendered
        #expect(throws: TOMLError.inline(line: 2, key: "plugins.\"zip.x\".tiles.other")) {
            try document.set(["plugins", "zip.x", "tiles", "other"], to: .bool(true))
        }
        #expect(throws: TOMLError.self) { try document.remove(["plugins", "zip.x", "tiles", "player"]) }
        #expect(document.rendered == before)
    }

    @Test func aLongArrayGetsALinePerElementInTheFilesLineEndings() throws {
        let apps: [TOMLValue] = ["com.apple.Safari", "com.mitchellh.ghostty", "com.tinyspeck.slackmacgap", "com.apple.Music"].map { .string($0) }
        var document = try TOMLDocument("[dock]\r\ntile-size = 56\r\n")
        try document.set(["dock", "pinned"], to: .array(apps))
        #expect(document.rendered == "[dock]\r\ntile-size = 56\r\npinned = [\r\n    \"com.apple.Safari\",\r\n    \"com.mitchellh.ghostty\",\r\n"
                                   + "    \"com.tinyspeck.slackmacgap\",\r\n    \"com.apple.Music\",\r\n]\r\n")
        try document.set(["dock", "pinned"], to: .array(Array(apps.prefix(1))))
        #expect(document.rendered == "[dock]\r\ntile-size = 56\r\npinned = [\"com.apple.Safari\"]\r\n")
    }

    @Test func valuesAreSpelledTheWayTheFileWritesThem() {
        #expect(TOMLValue.bool(false).spelled == "false")
        #expect(TOMLValue.number(8).spelled == "8")
        #expect(TOMLValue.number(0.5).spelled == "0.5")
        #expect(TOMLValue.string("a\"b\\c\td").spelled == #""a\"b\\c\td""#)
        #expect(TOMLValue.array([.number(1), .number(0.5)]).spelled == "[1, 0.5]")
        #expect(TOMLValue.array([]).spelled == "[]")
    }

    @Test func aKeyIsSpelledBareOrQuotedAsTheCharsetDemands() {
        #expect(TOMLTable.spell(key: "tile-size") == "tile-size")
        #expect(TOMLTable.spell(key: "zip.tanner.dock2.x") == "\"zip.tanner.dock2.x\"")
        #expect(TOMLTable.spell(key: "a b") == "\"a b\"")
        #expect(TOMLTable.spell(key: "") == "\"\"")
    }

    @Test func aRenameHoldsItsPlaceAndItsComment() throws {
        var document = try TOMLDocument(Self.trailingComments)
        try document.rename(["dock", "tile-size"], to: "tile-sise")
        #expect(Self.changedLines(Self.trailingComments, document.rendered) == ["tile-sise = 56    # a little larger"])
        #expect(throws: TOMLError.self) { try document.rename(["dock", "tile-sise"], to: "autohide") }
    }
}
