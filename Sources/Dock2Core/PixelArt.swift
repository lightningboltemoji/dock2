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

    private init(width: Int, height: Int, rows: [UInt64]) {
        self.width = width
        self.height = height
        self.rows = rows
    }

    public func isInk(x: Int, y: Int) -> Bool {
        rows[y] >> UInt64(width - 1 - x) & 1 == 1
    }

    /// The paper its ink closes off from the edge, as ink. Paper reaches paper only through a side, so a line
    /// of ink that steps diagonally still closes.
    public var inside: PixelArt {
        var outside = Set<Int>(), queue: [(x: Int, y: Int)] = []
        func reach(_ x: Int, _ y: Int) {
            guard (0..<width).contains(x), (0..<height).contains(y), !isInk(x: x, y: y),
                  outside.insert(y * width + x).inserted else { return }
            queue.append((x, y))
        }
        for x in 0..<width { reach(x, 0); reach(x, height - 1) }
        for y in 0..<height { reach(0, y); reach(width - 1, y) }
        while let (x, y) = queue.popLast() {
            reach(x - 1, y); reach(x + 1, y); reach(x, y - 1); reach(x, y + 1)
        }
        let rows = (0..<height).map { y in
            (0..<width).reduce(UInt64(0)) { $0 << 1 | (isInk(x: $1, y: y) || outside.contains(y * width + $1) ? 0 : 1) }
        }
        return PixelArt(width: width, height: height, rows: rows)
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
