import Dock2Core
import Dock2TOML
import Foundation
import Testing

@Suite struct CairoPictureTests {
    @Test func everyPictureParsesCroppedToItsInk() {
        #expect(CairoPicture.allCases.count == 59)
        for picture in CairoPicture.allCases {
            let art = picture.art
            #expect(art.width <= 40 && art.height <= 24, "\(picture)")
            #expect((0..<art.width).contains { art.isInk(x: $0, y: 0) }, "\(picture): a blank top row")
            #expect((0..<art.width).contains { art.isInk(x: $0, y: art.height - 1) }, "\(picture): a blank bottom row")
            #expect((0..<art.height).contains { art.isInk(x: 0, y: $0) }, "\(picture): a blank left column")
            #expect((0..<art.height).contains { art.isInk(x: art.width - 1, y: $0) }, "\(picture): a blank right column")
        }
    }

    @Test func titlesAreDistinct() {
        #expect(Set(CairoPicture.allCases.map(\.title)).count == CairoPicture.allCases.count)
    }
}

@Suite struct PixelArtTests {
    @Test func readsInkRowByRow() throws {
        let art = try #require(PixelArt("#..\n.##"))
        #expect(art.width == 3 && art.height == 2)
        #expect(art.isInk(x: 0, y: 0) && !art.isInk(x: 1, y: 0) && !art.isInk(x: 2, y: 0))
        #expect(!art.isInk(x: 0, y: 1) && art.isInk(x: 1, y: 1) && art.isInk(x: 2, y: 1))
    }

    @Test func refusesWhatIsNotAPicture() {
        #expect(PixelArt("") == nil)
        #expect(PixelArt("#.\n#") == nil)
        #expect(PixelArt("#x") == nil)
        #expect(PixelArt(String(repeating: "#", count: 65)) == nil)
    }

    /// The dog, 26 wide, on a 128 pt tile at 2×: five pixels apiece, its corner on a whole pixel.
    @Test func growsByWholePixelsOnWholePixels() {
        let dog = CairoPicture.dog.art
        let placement = dog.placement(side: 256, fraction: 0.5)
        #expect(placement.scale == 5)
        #expect(placement.x == ((256 - 26 * 5) / 2.0).rounded() && placement.y == ((256 - Double(dog.height) * 5) / 2).rounded())
    }

    @Test func roundsToTheNearestWholeScale() {
        let art = PixelArt(String(repeating: "#", count: 20))!
        #expect(art.placement(side: 100, fraction: 0.5).scale == 3)    // 2.5 rounds up
        #expect(art.placement(side: 92, fraction: 0.5).scale == 2)     // 2.3
        #expect(art.placement(side: 32, fraction: 0.5).scale == 1)     // 0.8 still gets a pixel apiece
    }

    @Test func insideIsThePaperItsInkEncloses() throws {
        let ring = try #require(PixelArt(".#.\n#.#\n.#."))
        // A ring whose ink steps diagonally still closes its middle.
        #expect(ring.inside == PixelArt("...\n.#.\n..."))
        let cup = try #require(PixelArt("#.#\n#.#\n###"))
        #expect(cup.inside == PixelArt("...\n...\n..."))
    }

    /// The strawberry's body is enclosed, and its seeds, being ink, are not inside.
    @Test func insideLeavesInkOut() {
        let strawberry = CairoPicture.strawberry.art, inside = strawberry.inside
        #expect(inside.isInk(x: 3, y: 12) && !inside.isInk(x: 6, y: 12) && strawberry.isInk(x: 6, y: 12))
        #expect(!inside.isInk(x: 0, y: 0))
    }

    @Test func scalesDownSmoothlyWhenTooSmallForAPixelApiece() {
        let art = PixelArt(String(repeating: "#", count: 40))!
        let placement = art.placement(side: 32, fraction: 0.5)
        #expect(placement.scale == 0.4)
        #expect(placement.x == 8)
    }
}

@Suite struct PixelSnappedTests {
    /// A 41.3 pt tile at 2× is 82.6 px: it becomes 83, its corner on a whole pixel.
    @Test func snapsOriginAndSizeToWholePixels() {
        let snapped = pixelSnapped(CGRect(x: 640.725, y: 10.35, width: 41.3, height: 41.3), scale: 2)
        #expect(snapped == CGRect(x: 640.5, y: 10.5, width: 41.5, height: 41.5))
    }
}

@Suite struct TileIconsTests {
    static func read(_ text: String) throws -> SettingsReading {
        Settings.read(try TOMLTable.parse(text))
    }

    static let safari = TileIconKey.app(AppRef(bundleIdentifier: "com.apple.Safari", path: ""))

    @Test func everyShapeReadsInTheFilesOrder() throws {
        let reading = try Self.read("""
        [icons]
        files = { picture = "strawberry", color = "#D87087" }
        "com.apple.Safari" = "icons/safari.car"
        "com.mitchellh.ghostty" = { file = "icons/pack.car", name = "ghostty" }
        "com.apple.Notes" = { picture = "pear", filled = false }
        "/Applications/Old.app" = "~/Icons/old.car"
        "com.apple.TextEdit" = { app = "com.apple.finder" }
        """)
        #expect(reading.diagnostics.isEmpty)
        #expect(reading.icons.entries.map(\.key.key) == ["files", "com.apple.Safari", "com.mitchellh.ghostty", "com.apple.Notes", "/Applications/Old.app",
                                                         "com.apple.TextEdit"])
        #expect(reading.icons.entries.map(\.line) == [2, 3, 4, 5, 6, 7])
        #expect(reading.icons[.app(AppRef(bundleIdentifier: "com.apple.TextEdit", path: ""))] == .app(.finder))
        #expect(reading.icons[.files] == .picture(PictureIcon(picture: .strawberry, color: IconColor(red: 216 / 255, green: 112 / 255, blue: 135 / 255))))
        #expect(reading.icons[Self.safari] == .file(path: "icons/safari.car", name: nil))
        #expect(reading.icons[.app(AppRef(bundleIdentifier: "com.mitchellh.ghostty", path: "/Applications/Ghostty.app"))]
                == .file(path: "icons/pack.car", name: "ghostty"))
        #expect(reading.icons[.app(AppRef(bundleIdentifier: "com.apple.Notes", path: ""))]
                == .picture(PictureIcon(picture: .pear, color: .violet, filled: false)))
        #expect(reading.icons[.app(AppRef(bundleIdentifier: nil, path: "/Applications/Old.app"))] == .file(path: "~/Icons/old.car", name: nil))
    }

    /// A bundle identifier is compared as LaunchServices compares it, without case.
    @Test func anAppIsKeyedAsPinnedListsIt() throws {
        let reading = try Self.read("[icons]\n\"com.apple.safari\" = \"a.car\"\n")
        #expect(reading.icons[Self.safari] == .file(path: "a.car", name: nil))
        #expect(TileIconKey(key: "files") == .files)
        #expect(TileIconKey(key: "") == nil)
        #expect(TileIconKey(key: "~/Applications/Old.app")?.key == "~/Applications/Old.app")
    }

    @Test func aShapeItCannotReadIsADiagnosticOnItsLineAndTheTileWearsItsOwn() throws {
        let reading = try Self.read("""
        [icons]
        files = { picture = "teapot" }
        "com.apple.Safari" = 3
        "com.apple.Notes" = { file = "a.car", colour = "#000000" }
        "com.apple.Mail" = { name = "mail" }
        "com.apple.Maps" = { picture = "pear", color = "green", filled = "yes" }
        "com.apple.Music" = ""
        "com.apple.SAFARI" = "b.car"
        "com.apple.TV" = "c.car"
        "com.apple.Photos" = { app = "" }
        """)
        #expect(reading.icons.entries.map(\.key.key) == ["com.apple.SAFARI", "com.apple.TV"])
        #expect(reading.diagnostics.map(\.description) == [
            "line 2: 'icons.files' has a picture that must be one of Cairo's pictures, not \"teapot\"",
            "line 3: 'icons.\"com.apple.Safari\"' must be a file in quotes, or a table — { file, name }, { picture, color, filled } or { app } — not a number",
            "line 4: 'icons.\"com.apple.Notes\"' has 'colour', which an icon doesn't: it is { file, name }, { picture, color, filled } or { app }",
            "line 5: 'icons.\"com.apple.Mail\"' must give a file, a picture or an app",
            "line 6: 'icons.\"com.apple.Maps\"' has a color that must be a colour like \"#6A5CD8\", not \"green\"",
            "line 6: 'icons.\"com.apple.Maps\"' has filled, which must be true or false, not a string",
            "line 7: 'icons.\"com.apple.Music\"' names no file",
            "line 10: 'icons.\"com.apple.Photos\"' has an app that must be a bundle identifier or a path in quotes, not an empty one",
        ])
    }

    @Test func theSameAppTwiceIsADiagnostic() throws {
        let reading = try Self.read("[icons]\n\"com.apple.Safari\" = \"a.car\"\n\"com.apple.safari\" = \"b.car\"\n")
        #expect(reading.icons[Self.safari] == .file(path: "a.car", name: nil))
        #expect(reading.diagnostics.map(\.description) == ["line 3: 'icons.\"com.apple.safari\"' is the same app as line 2"])
    }

    /// A string for a catalog of one, a table otherwise, saying only what is not a picture's default; nil takes
    /// the line out.
    @Test func anEditWritesOnlyWhatDiffers() throws {
        var document = try TOMLDocument("[icons]\nfiles = \"old.car\"\n")
        for edit in [
            TileIcons.edit(.files, .picture(PictureIcon(picture: .eyeOfHorus, color: IconColor(red: 106 / 255, green: 92 / 255, blue: 216 / 255)))),
            TileIcons.edit(Self.safari, .file(path: "icons/safari.car", name: nil)),
            TileIcons.edit(.app(AppRef(bundleIdentifier: "com.mitchellh.ghostty", path: "")), .file(path: "icons/pack.car", name: "ghostty")),
            TileIcons.edit(.app(AppRef(bundleIdentifier: "com.apple.Notes", path: "")),
                           .picture(PictureIcon(picture: .pear, color: IconColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255), filled: false))),
            TileIcons.edit(.app(AppRef(bundleIdentifier: "com.apple.TextEdit", path: "")), .app(.finder)),
        ] { try document.apply(edit) }
        #expect(document.rendered == """
        [icons]
        files = { picture = "eye-of-horus" }
        "com.apple.Safari" = "icons/safari.car"
        "com.mitchellh.ghostty" = { file = "icons/pack.car", name = "ghostty" }
        "com.apple.Notes" = { picture = "pear", color = "#34C759", filled = false }
        "com.apple.TextEdit" = { app = "com.apple.finder" }

        """)
        let reading = Settings.read(document.table)
        #expect(reading.diagnostics.isEmpty && reading.icons.entries.count == 5)
        try document.apply(TileIcons.edit(.files, nil))
        #expect(!document.rendered.contains("files ="))
    }

    @Test func aPathIsTheSettingsFoldersUnlessItStartsAtHomeOrTheRoot() {
        #expect(TileIcons.resolve("icons/safari.car", against: "/Users/x/dotfiles/dock2") == "/Users/x/dotfiles/dock2/icons/safari.car")
        #expect(TileIcons.resolve("../shared/a.car", against: "/Users/x/dotfiles/dock2") == "/Users/x/dotfiles/shared/a.car")
        #expect(TileIcons.resolve("/Library/a.car", against: "/Users/x") == "/Library/a.car")
        #expect(TileIcons.resolve("~/Icons/a.car", against: "/Users/x/dotfiles") == NSHomeDirectory() + "/Icons/a.car")
    }
}

@Suite struct IconCatalogContentsTests {
    static func contents(_ assets: [[String: Any]]) throws -> IconCatalogContents {
        try IconCatalogContents(assetutilJSON: JSONSerialization.data(withJSONObject: [["AssetStorageVersion": "x"]] + assets))
    }

    /// Calculator's: the stack in three appearances, and the flat renditions an older macOS draws.
    @Test func anIconComposerIconIsAStack() throws {
        let calculator = try Self.contents([
            ["AssetType": "Icon Image", "Name": "AppIcon"],
            ["AssetType": "IconImageStack", "Name": "AppIcon", "Appearance": "NSAppearanceNameDarkAqua"],
            ["AssetType": "IconImageStack", "Name": "AppIcon", "Appearance": "NSAppearanceNameAqua"],
            ["AssetType": "MultiSized Image", "Name": "AppIcon"],
            ["AssetType": "Vector Glyph", "Name": "plus"],
        ])
        #expect(calculator.icons == ["AppIcon"])
        #expect(try calculator.icon(named: nil) == "AppIcon")
        #expect(throws: IconFileProblem.unnamed("Calculator", ["AppIcon"])) { try calculator.icon(named: "Calculator") }
    }

    @Test func aPackNeedsANameAndAFlatIconIsRefused() throws {
        let pack = try Self.contents([["AssetType": "IconImageStack", "Name": "chrome"], ["AssetType": "IconImageStack", "Name": "ghostty"]])
        #expect(throws: IconFileProblem.several(["chrome", "ghostty"])) { try pack.icon(named: nil) }
        #expect(try pack.icon(named: "ghostty") == "ghostty")
        let flat = try Self.contents([["AssetType": "Icon Image", "Name": "AppIcon"], ["AssetType": "MultiSized Image", "Name": "AppIcon"]])
        #expect(throws: IconFileProblem.flat) { try flat.icon(named: nil) }
        #expect(throws: IconFileProblem.noIcon) { try Self.contents([["AssetType": "Image", "Name": "x"]]).icon(named: nil) }
        #expect(throws: IconFileProblem.notCatalog) { try IconCatalogContents(assetutilJSON: Data("not json".utf8)) }
    }
}
