import Foundation

/// How the dock is drawn ([visual](../../.agents/product/visual.md#the-docks-style)).
public enum DockStyle: String, Sendable, CaseIterable, Codable {
    /// macOS 27's: the tiles on a platter of Liquid Glass.
    case glass
    /// Mac OS X 10.6's: the tiles standing on a shelf that mirrors them and the screen above it.
    case snowLeopard

    public var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .snowLeopard: "Snow Leopard"
        }
    }
}
