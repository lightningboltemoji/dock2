import Foundation

/// One of Cairo's pictures on a colour, as a tile wears it in place of its own icon
/// ([icons](../../.agents/product/icons.md#cairos-pictures)).
public struct PictureIcon: Sendable, Hashable {
    public var picture: CairoPicture
    /// The plate behind the picture.
    public var color: IconColor
    /// The picture's ink black and the paper it encloses white, rather than its ink white; on by default.
    public var filled: Bool

    public init(picture: CairoPicture, color: IconColor = .violet, filled: Bool = true) {
        self.picture = picture
        self.color = color
        self.filled = filled
    }

    /// The picture's longer side, as a fraction of the plate.
    public static let pictureFraction = 0.62
}

/// A colour as Display P3's components, each 0 to 1: the space the plate is blended in.
public struct IconColor: Sendable, Hashable {
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

    /// A tint's plate: the system colour's components, read as Display P3's.
    public init(_ tint: Tint) {
        let (red, green, blue): (Double, Double, Double) = switch tint {
        case .red: (255, 59, 48)
        case .orange: (255, 149, 0)
        case .yellow: (255, 204, 0)
        case .green: (52, 199, 89)
        case .blue: (0, 122, 255)
        case .purple: (175, 82, 222)
        case .pink: (255, 45, 85)
        case .gray: (142, 142, 147)
        }
        self.init(red: red / 255, green: green / 255, blue: blue / 255)
    }
}
