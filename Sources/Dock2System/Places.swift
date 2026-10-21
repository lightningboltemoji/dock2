import Foundation

/// A place Files opens at: one of Home's folders, Applications, iCloud Drive, or a mounted volume.
public struct Place: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case home, desktop, documents, downloads, applications, iCloudDrive
        case volume(internal: Bool, local: Bool)
    }

    public var name: String
    public var url: URL
    public var kind: Kind

    public init(name: String, url: URL, kind: Kind) {
        self.name = name
        self.url = url
        self.kind = kind
    }

    /// Which of `places` holds `folder`, the nearest when several do: Home over the disk it is on.
    public static func holding(_ folder: URL, in places: [Place]) -> Int? {
        let path = folder.standardizedFileURL.path
        func base(_ index: Int) -> String { places[index].url.standardizedFileURL.path }
        return places.indices.filter { index in
            path == base(index) || path.hasPrefix(base(index).hasSuffix("/") ? base(index) : base(index) + "/")
        }.max { base($0).count < base($1).count }
    }
}

/// The places Files opens at ([files](product/files/README.md#layout)), for its places pop-up and the
/// Finder tile's menu: Home, its three folders, Applications, iCloud Drive if there is one, and each mounted volume.
public enum Places {
    public static var all: [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var places = [Place(name: "Home", url: home, kind: .home)]
        for (name, kind) in [("Desktop", Place.Kind.desktop), ("Documents", .documents), ("Downloads", .downloads)] {
            places.append(Place(name: name, url: home.appendingPathComponent(name), kind: kind))
        }
        places.append(Place(name: "Applications", url: URL(fileURLWithPath: "/Applications"), kind: .applications))
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: cloud.path) { places.append(Place(name: "iCloud Drive", url: cloud, kind: .iCloudDrive)) }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            places.append(Place(name: values?.volumeLocalizedName ?? volume.lastPathComponent, url: volume,
                                kind: .volume(internal: values?.volumeIsInternal ?? false, local: values?.volumeIsLocal ?? true)))
        }
        return places
    }
}
