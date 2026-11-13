import Foundation

/// What a compiled asset catalog (`Assets.car`) holds that a tile can wear, as `assetutil --info` lists it
/// ([icons](../../.agents/product/icons.md#icon-composers-icons)).
public struct IconCatalogContents: Equatable, Sendable, Codable {
    /// Its Icon Composer icons — `IconImageStack`s — by name, in the catalog's order.
    public let icons: [String]
    /// It holds an icon of the flat kind, as apps made before Liquid Glass ship.
    public let hasFlatIcon: Bool

    public init(icons: [String], hasFlatIcon: Bool) {
        self.icons = icons
        self.hasFlatIcon = hasFlatIcon
    }

    /// `assetutil --info`'s JSON: a header, then one object for each of the catalog's renditions.
    public init(assetutilJSON data: Data) throws(IconFileProblem) {
        guard let assets = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !assets.isEmpty else {
            throw IconFileProblem.notCatalog
        }
        var icons: [String] = []
        var flat = false
        for asset in assets.dropFirst() {
            switch asset["AssetType"] as? String {
            case "IconImageStack":
                if let name = asset["Name"] as? String, !icons.contains(name) { icons.append(name) }
            case "Icon Image", "MultiSized Image":
                flat = true
            default:
                break
            }
        }
        self.init(icons: icons, hasFlatIcon: flat)
    }

    /// The icon an entry naming `name` — or none, for a catalog of one — wears.
    public func icon(named name: String?) throws(IconFileProblem) -> String {
        if icons.isEmpty { throw hasFlatIcon ? .flat : .noIcon }
        guard let name else {
            guard icons.count == 1 else { throw .several(icons) }
            return icons[0]
        }
        guard icons.contains(name) else { throw .unnamed(name, icons) }
        return name
    }
}

/// Why a file `[icons]` names gives its tile nothing to wear.
public enum IconFileProblem: Error, Equatable, Sendable {
    case missing
    case unreadable(String)
    /// Not an asset catalog `assetutil` can read.
    case notCatalog
    case noIcon
    /// Its icon is flat: an app's from before Liquid Glass, not an Icon Composer icon.
    case flat
    /// A pack, and the entry names none of its icons.
    case several([String])
    /// The entry names an icon the pack doesn't have.
    case unnamed(String, [String])

    /// What follows "names icons/pack.car, which" in a diagnostic.
    public var reason: String {
        switch self {
        case .missing: "isn't there"
        case .unreadable(let why): "can't be read: \(why)"
        case .notCatalog: "isn't a compiled icon, an asset catalog (.car)"
        case .noIcon: "holds no icon"
        case .flat: "holds a flat icon, as apps made before Liquid Glass ship, rather than an Icon Composer one"
        case .several(let icons): "holds several icons — \(Self.list(icons)) — so it needs a name"
        case .unnamed(let name, let icons): "has no icon named \"\(name)\", only \(Self.list(icons))"
        }
    }

    private static func list(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}
