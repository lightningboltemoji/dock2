import CryptoKit
import Dock2Core
import Foundation

/// A compiled asset catalog, read with `assetutil --info`: in `/usr/bin` on every macOS, not an Xcode shim.
public enum IconCatalog {
    /// The file's SHA-256, in hex: what names its shims, and its contents once read.
    public static func hash(of url: URL) throws(IconFileProblem) -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw .missing
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What it holds, off the main actor.
    public static func read(_ url: URL) async throws(IconFileProblem) -> IconCatalogContents {
        let output = await Task.detached { run(url) }.value
        guard let output else { throw .notCatalog }
        return try IconCatalogContents(assetutilJSON: output)
    }

    private static func run(_ url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/assetutil")
        process.arguments = ["--info", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            warn("could not run assetutil: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// A bundle macOS draws one icon of a catalog from, as it draws an app's: `NSWorkspace.icon(forFile:)` reads
/// `CFBundleIconName` from `Assets.car`, the glass and the system's icon style included. An `.appex` with no
/// executable is drawn clean and is not registered with Launch Services, as an `.app` would be.
public enum IconShim {
    public static let folder = Paths.directory.appendingPathComponent("Icons", isDirectory: true)

    /// Named by content: IconServices caches by bundle, so a changed catalog is a new path.
    public static func url(hash: String, icon: String, in folder: URL = folder) -> URL {
        let name = icon.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent("\(hash)-\(name).appex", isDirectory: true)
    }

    /// The shim for `icon` of the catalog at `catalog`, written unless it is there already.
    @discardableResult
    public static func make(catalog: URL, hash: String, icon: String, in folder: URL = folder) throws -> URL {
        let url = url(hash: hash, icon: icon, in: folder)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { return url }
        // Built aside and moved in whole, so a shim is never seen half-written.
        let building = folder.appendingPathComponent(".\(UUID().uuidString).appex", isDirectory: true)
        let resources = building.appendingPathComponent("Contents/Resources", isDirectory: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: building) }
        let info: [String: Any] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "XPC!",
            "CFBundleIconName": icon,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: building.appendingPathComponent("Contents/Info.plist"))
        try manager.copyItem(at: catalog, to: resources.appendingPathComponent("Assets.car"))
        do {
            try manager.moveItem(at: building, to: url)
        } catch where manager.fileExists(atPath: url.path) {
            // Another made it meanwhile: the same content, so the same shim.
        }
        return url
    }

    /// Removes every shim but those in `keeping`.
    public static func prune(keeping: Set<URL>, in folder: URL = folder) {
        let kept = Set(keeping.map(\.standardizedFileURL.path))
        let shims = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for shim in shims where shim.pathExtension == "appex" && !kept.contains(shim.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: shim)
        }
    }
}
