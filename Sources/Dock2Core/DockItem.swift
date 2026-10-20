import Foundation

/// One tile: an application, named by bundle identifier so it survives the app moving.
public struct DockItem: Sendable, Hashable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    /// The tiles dock2 shows, left to right. Static until dock2 has a configuration.
    public static let pinned: [DockItem] = [
        DockItem(bundleIdentifier: "com.apple.Safari"),
        DockItem(bundleIdentifier: "com.mitchellh.ghostty"),
    ]

    /// `pinned`, unless `DOCK2_ITEMS` names other bundle identifiers, comma-separated: a development
    /// knob until there is a configuration.
    public static func pinned(environment: [String: String]) -> [DockItem] {
        guard let list = environment["DOCK2_ITEMS"] else { return pinned }
        return list.split(separator: ",").map { DockItem(bundleIdentifier: $0.trimmingCharacters(in: .whitespaces)) }
    }
}
