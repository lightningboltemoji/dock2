import Foundation

/// An application, named by bundle identifier so it survives the app moving, with the path it was found
/// at for when it has none.
public struct AppRef: Sendable, Hashable, Codable, CustomStringConvertible {
    public var bundleIdentifier: String?
    public var path: String

    public init(bundleIdentifier: String?, path: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }

    /// What identifies the app: its bundle identifier, which LaunchServices compares without case, else
    /// its path.
    public var identity: String {
        bundleIdentifier.map { "id:\($0.lowercased())" } ?? "path:\(path)"
    }

    public static func == (lhs: AppRef, rhs: AppRef) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    public var description: String { bundleIdentifier ?? path }

    public static let finder = AppRef(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")
}
