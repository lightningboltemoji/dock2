import Foundation

/// A one-bit picture, row 0 at the top ([icon](../../.agents/product/files/icon.md)).
public struct PixelArt: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Each row's ink, its leftmost pixel in bit `width - 1`.
    private let rows: [UInt64]

    /// From rows of `#` (ink) and `.`, one to a line; nil for any other character, rows of unequal width, or
    /// a row wider than 64.
    public init?(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let width = lines.first?.count, width > 0, width <= 64,
              lines.allSatisfy({ $0.count == width && $0.allSatisfy { $0 == "#" || $0 == "." } }) else { return nil }
        self.width = width
        height = lines.count
        rows = lines.map { $0.reduce(UInt64(0)) { $0 << 1 | ($1 == "#" ? 1 : 0) } }
    }

    public func isInk(x: Int, y: Int) -> Bool {
        rows[y] >> UInt64(width - 1 - x) & 1 == 1
    }

    /// Where it goes, centred in a square of `side` pixels with its longer side near `fraction` of it.
    public func placement(side: Int, fraction: Double) -> Placement {
        let ideal = fraction * Double(side) / Double(max(width, height))
        // Each of its pixels a whole number of the screen's, on whole pixels; too small for one apiece, it
        // is scaled down smoothly instead, rather than outgrow the square.
        let scale = ideal >= Self.smallestWhole ? max(1, ideal.rounded()) : ideal
        let x = (Double(side) - Double(width) * scale) / 2, y = (Double(side) - Double(height) * scale) / 2
        return scale == scale.rounded() ? Placement(scale: scale, x: x.rounded(), y: y.rounded()) : Placement(scale: scale, x: x, y: y)
    }

    /// How far short of one screen pixel per pixel a picture may be and still get one, growing to 4/3 of its size.
    static let smallestWhole = 0.75

    /// The picture's scale, and its top left corner from the square's: whole numbers unless it is scaled down.
    public struct Placement: Sendable, Equatable {
        public let scale: Double
        public let x: Double
        public let y: Double
    }
}

extension PixelArt {
    /// Cairo's, parsed once.
    static let cairo: [CairoPicture: PixelArt] = Dictionary(uniqueKeysWithValues: CairoPicture.allCases.map { ($0, PixelArt($0.rows)!) })
}
