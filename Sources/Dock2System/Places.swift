import Foundation

/// The places Files opens at ([files](product/files/README.md#layout)), for the path bar's menu and the Finder
/// tile's: Home, its three folders, Applications, iCloud Drive if there is one, and each mounted volume.
public enum Places {
    public static var all: [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var places: [(name: String, url: URL)] = [("Home", home)]
        for name in ["Desktop", "Documents", "Downloads"] { places.append((name, home.appendingPathComponent(name))) }
        places.append(("Applications", URL(fileURLWithPath: "/Applications")))
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: cloud.path) { places.append(("iCloud Drive", cloud)) }
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? [] {
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? volume.lastPathComponent
            places.append((name, volume))
        }
        return places
    }
}
