import Dock2Core
import Foundation

/// A place Files opens at: one of Home's folders, Applications, iCloud Drive, a disk, a server, or Network.
public struct Place: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case home, desktop, documents, downloads, applications, iCloudDrive
        case volume(internal: Bool, local: Bool)
        case server
        case network
    }

    public var name: String
    public var url: URL
    public var kind: Kind
    /// What it holds besides itself: a server's mounted shares.
    public var shares: [URL] = []
    /// ⏏ beside it: a disk that comes out, a server connected to.
    public var ejects = false

    public init(name: String, url: URL, kind: Kind) {
        self.name = name
        self.url = url
        self.kind = kind
    }

    /// Which of `places` holds `folder`, the nearest when several do: Home over the disk it is on, a server
    /// over its shares.
    public static func holding(_ folder: URL, in places: [Place]) -> Int? {
        func depth(_ index: Int) -> Int? {
            ([places[index].url] + places[index].shares).compactMap { folder.relative(to: $0)?.count }.min()
        }
        return places.indices.compactMap { index in depth(index).map { (index, $0) } }.min { $0.1 < $1.1 }?.0
    }

    /// Where the place holding the last of `path`, a folder's ancestors from its root down to it, starts along `path`:
    /// what comes before lies outside that place.
    public static func start(along path: [URL], in places: [Place]) -> Int {
        guard let folder = path.last else { return 0 }
        let place = holding(folder, in: places)
        return path.lastIndex { holding($0, in: places) != place }.map { $0 + 1 } ?? 0
    }
}

/// The places Files opens at ([files](product/files/README.md#layout)), for its places pop-up and the Finder
/// tile's menu: Home, its three folders, Applications, iCloud Drive if there is one, each disk, each server
/// connected to — its shares not places of their own — and Network.
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
        let servers = Servers.connected
        let shares = Set(servers.flatMap(\.shares))
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        where !shares.contains(volume.canonical) {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            var place = Place(name: values?.volumeLocalizedName ?? volume.lastPathComponent, url: volume,
                              kind: .volume(internal: values?.volumeIsInternal ?? false, local: values?.volumeIsLocal ?? true))
            place.ejects = Servers.ejects(volume)
            places.append(place)
        }
        for server in servers {
            var place = Place(name: server.name, url: server.url, kind: .server)
            place.shares = server.shares
            place.ejects = true
            places.append(place)
        }
        places.append(Place(name: "Network", url: Servers.network, kind: .network))
        return places
    }
}
