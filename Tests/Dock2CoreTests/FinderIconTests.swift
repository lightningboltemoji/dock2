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

@Suite struct FinderIconTests {
    static func read(_ text: String) throws -> SettingsReading {
        Settings.read(try TOMLTable.parse(text))
    }

    @Test func storesThePictureTheColourAndTheFill() throws {
        let reading = try Self.read("[files]\nicon = \"palm-tree\"\nicon-color = \"#1A9999\"\nicon-filled = false\n")
        #expect(reading[Settings.finderIcon] == FinderIcon(picture: .palmTree, color: IconColor(red: 26 / 255, green: 153 / 255, blue: 153 / 255),
                                                            filled: false))
    }

    /// Finder's own icon is a word of its own, and keeps the colour for the next picture.
    @Test func finderOwnKeepsTheColour() throws {
        let reading = try Self.read("[files]\nicon = \"finder\"\nicon-color = \"#E66619\"\n")
        #expect(reading[Settings.finderIcon].picture == nil)
        #expect(reading[Settings.finderIcon].color == IconColor(red: 230 / 255, green: 102 / 255, blue: 25 / 255))
        #expect(FinderIcon().filled)
    }

    @Test func aPictureNotKnownIsADiagnostic() throws {
        let reading = try Self.read("[files]\nicon = \"teapot\"\n")
        #expect(reading[Settings.finderIcon] == FinderIcon())
        #expect(reading.diagnostics.map(\.message) == ["'files.icon' must be \"finder\" or one of Cairo's pictures, not \"teapot\""])
    }
}
