import AppKit
import Dock2Core
import Dock2System
import Foundation
import Testing

/// Against Calculator's catalog, which every macOS 26 has, and the two `make fixtures` compiles into
/// `.build/fixtures`: a pack of two Icon Composer icons, `red` and `blue`, and a flat icon.
enum IconFixtures {
    static let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/Resources/Assets.car")
    private static let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/fixtures")
    static let pack = built.appendingPathComponent("pack.car")
    static let flat = built.appendingPathComponent("flat.car")

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@Suite struct IconCatalogTests {
    @Test func readsTheIconComposerIconsACatalogHolds() async throws {
        #expect(try await IconCatalog.read(IconFixtures.calculator).icons == ["AppIcon"])
        let pack = try await IconCatalog.read(IconFixtures.pack)
        #expect(Set(pack.icons) == ["red", "blue"])
        #expect(throws: IconFileProblem.several(pack.icons)) { try pack.icon(named: nil) }
        let flat = try await IconCatalog.read(IconFixtures.flat)
        #expect(flat.icons.isEmpty && flat.hasFlatIcon)
    }

    @Test func refusesWhatIsNotACatalog() async throws {
        let folder = try IconFixtures.folder()
        let text = folder.appendingPathComponent("not.car")
        try Data("not a catalog".utf8).write(to: text)
        await #expect(throws: IconFileProblem.notCatalog) { try await IconCatalog.read(text) }
        #expect(throws: IconFileProblem.missing) { try IconCatalog.hash(of: folder.appendingPathComponent("gone.car")) }
        #expect(try IconCatalog.hash(of: text).count == 64)
    }
}

@MainActor
@Suite struct IconShimTests {
    @Test func aShimIsInfoAndACopyOfTheCatalogNamedByContent() throws {
        let folder = try IconFixtures.folder()
        let hash = try IconCatalog.hash(of: IconFixtures.calculator)
        let shim = try IconShim.make(catalog: IconFixtures.calculator, hash: hash, icon: "AppIcon", in: folder)
        #expect(shim == folder.appendingPathComponent("\(hash)-AppIcon.appex", isDirectory: true))
        let info = try #require(NSDictionary(contentsOf: shim.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        #expect(info["CFBundlePackageType"] as? String == "XPC!")
        #expect(info["CFBundleIconName"] as? String == "AppIcon")
        #expect(info["CFBundleExecutable"] == nil)
        let copy = shim.appendingPathComponent("Contents/Resources/Assets.car")
        #expect(try Data(contentsOf: copy) == Data(contentsOf: IconFixtures.calculator))
        // Made again, it is the one already there.
        #expect(try IconShim.make(catalog: IconFixtures.calculator, hash: hash, icon: "AppIcon", in: folder) == shim)
        IconShim.prune(keeping: [], in: folder)
        #expect(!FileManager.default.fileExists(atPath: shim.path))
    }

    /// The premise: macOS draws a catalog through its shim as it draws the app the catalog came from.
    @Test func aShimIsDrawnAsTheAppItsCatalogCameFromIs() throws {
        let folder = try IconFixtures.folder()
        let shim = try IconShim.make(catalog: IconFixtures.calculator, hash: try IconCatalog.hash(of: IconFixtures.calculator),
                                     icon: "AppIcon", in: folder)
        let drawn = try Self.pixels(NSWorkspace.shared.icon(forFile: shim.path))
        let own = try Self.pixels(NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app"))
        #expect(zip(drawn, own).map { abs(Int($0) - Int($1)) }.max() ?? 255 <= 4)
        let generic = try Self.pixels(NSWorkspace.shared.icon(for: .applicationExtension))
        #expect(zip(drawn, generic).map { abs(Int($0) - Int($1)) }.max() ?? 0 > 32)
    }

    private static func pixels(_ image: NSImage, side: Int = 256) throws -> [UInt8] {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: side * 4, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: side * side * 4))
    }
}

@MainActor
@Suite struct TileIconFilesTests {
    static let safari = TileIconKey.app(AppRef(bundleIdentifier: "com.apple.Safari", path: ""))
    static let notes = TileIconKey.app(AppRef(bundleIdentifier: "com.apple.Notes", path: ""))
    static let mail = TileIconKey.app(AppRef(bundleIdentifier: "com.apple.Mail", path: ""))

    static func icons(_ entries: [(TileIconKey, TileIcon)]) -> TileIcons {
        TileIcons(entries: entries.enumerated().map { TileIcons.Entry(key: $1.0, icon: $1.1, line: $0 + 2) })
    }

    /// Waits for the files not seen before to be read.
    static func read(_ files: TileIconFiles) async {
        await withCheckedContinuation { done in files.onChange = { done.resume() } }
    }

    /// Waits up to five seconds for `condition`.
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aFileIsCheckedOnceAndKnownFromThenOn() async throws {
        let settings = try IconFixtures.folder(), shims = try IconFixtures.folder()
        try FileManager.default.createDirectory(at: settings.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: IconFixtures.pack, to: settings.appendingPathComponent("icons/pack.car"))
        let icons = Self.icons([(.files, .file(path: "icons/pack.car", name: "blue")), (Self.safari, .picture(PictureIcon(picture: .dog)))])

        let files = TileIconFiles(folder: shims)
        #expect(!files.update(icons, base: settings))
        #expect(files.shim(for: .files) == nil)
        await Self.read(files)
        let shim = try #require(files.shim(for: .files))
        #expect(shim.lastPathComponent.hasSuffix("-blue.appex"))
        #expect(files.diagnostics.isEmpty)

        // Another launch: known by its hash, so drawn from the start.
        let again = TileIconFiles(folder: shims)
        #expect(again.update(icons, base: settings))
        #expect(again.shim(for: .files) == shim)
    }

    @Test func aFileThatGivesNothingToWearIsADiagnosticOnItsLine() async throws {
        let settings = try IconFixtures.folder(), shims = try IconFixtures.folder()
        let files = TileIconFiles(folder: shims)
        files.update(Self.icons([
            (.files, .file(path: "missing.car", name: nil)),
            (Self.safari, .file(path: IconFixtures.pack.path, name: nil)),
            (Self.notes, .file(path: IconFixtures.pack.path, name: "green")),
            (Self.mail, .file(path: IconFixtures.flat.path, name: nil)),
        ]), base: settings)
        try await Self.until { files.diagnostics.count == 4 }
        let pack = IconFixtures.pack.path, flat = IconFixtures.flat.path
        let reasons = try await IconCatalog.read(IconFixtures.pack).icons.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(files.diagnostics.map(\.description) == [
            "line 2: 'icons.files' names missing.car, which isn't there",
            "line 3: 'icons.\"com.apple.Safari\"' names \(pack), which holds several icons — \(reasons) — so it needs a name",
            "line 4: 'icons.\"com.apple.Notes\"' names \(pack), which has no icon named \"green\", only \(reasons)",
            "line 5: 'icons.\"com.apple.Mail\"' names \(flat), which holds a flat icon, as apps made before Liquid Glass ship, rather than an Icon Composer one",
        ])
        #expect([TileIconKey.files, Self.safari, Self.notes, Self.mail].allSatisfy { files.shim(for: $0) == nil })
    }

    /// Named where it is under the settings' folder; otherwise copied into `icons/` once, past a different file
    /// of its name.
    @Test func aChosenFileIsPlacedBesideTheSettings() throws {
        let settings = try IconFixtures.folder(), elsewhere = try IconFixtures.folder()
        let manager = FileManager.default
        let pack = elsewhere.appendingPathComponent("pack.car")
        try manager.copyItem(at: IconFixtures.pack, to: pack)
        let hash = try IconCatalog.hash(of: pack)
        #expect(try TileIconFiles.place(pack, hash: hash, in: settings) == "icons/pack.car")
        #expect(try TileIconFiles.place(pack, hash: hash, in: settings) == "icons/pack.car")
        let other = elsewhere.appendingPathComponent("other/pack.car")
        try manager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: IconFixtures.flat, to: other)
        #expect(try TileIconFiles.place(other, hash: try IconCatalog.hash(of: other), in: settings) == "icons/pack-2.car")
        let inside = settings.appendingPathComponent("mine/flat.car")
        try manager.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: IconFixtures.flat, to: inside)
        #expect(try TileIconFiles.place(inside, hash: try IconCatalog.hash(of: inside), in: settings) == "mine/flat.car")
        #expect(try manager.contentsOfDirectory(atPath: settings.appendingPathComponent("icons").path).sorted() == ["pack-2.car", "pack.car"])
    }
}
