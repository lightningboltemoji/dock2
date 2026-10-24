import Foundation

/// What the Finder tile wears ([icon](../../.agents/product/files/icon.md)).
public struct FinderIcon: Sendable, Hashable, Codable {
    /// One of Cairo's pictures, or nil for Finder's own icon.
    public var picture: CairoPicture?
    /// The plate behind the picture; kept while Finder's own icon shows, for the next picture.
    public var color: IconColor
    /// The picture's ink black and the paper it encloses white, rather than its ink white; on by default.
    public var filled: Bool

    public init(picture: CairoPicture? = nil, color: IconColor = .violet, filled: Bool = true) {
        self.picture = picture
        self.color = color
        self.filled = filled
    }

    /// An icon stored without `filled` is filled, as a new one is.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        picture = try container.decodeIfPresent(CairoPicture.self, forKey: .picture)
        color = try container.decode(IconColor.self, forKey: .color)
        filled = try container.decodeIfPresent(Bool.self, forKey: .filled) ?? true
    }

    /// The picture's longer side, as a fraction of the plate.
    public static let pictureFraction = 0.62
}

/// A colour as Display P3's components, each 0 to 1: the space the plate is blended in.
public struct IconColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// dock2's own app icon's plate, `#6A5CD8`: eight bits a channel, as the config file writes a colour.
    public static let violet = IconColor(red: 106 / 255, green: 92 / 255, blue: 216 / 255)
}
