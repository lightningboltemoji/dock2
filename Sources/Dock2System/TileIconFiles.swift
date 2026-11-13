import Dock2Core
import Foundation
import Observation

/// The `[icons]` entries that name files, each checked and given a shim to be drawn through. A catalog read
/// once is known by its hash from then on, on every launch after, so only a file never seen waits on `assetutil`.
@MainActor
@Observable
public final class TileIconFiles {
    /// Each entry whose file gives its tile nothing to wear, on its line. Its tile wears its own icon.
    public private(set) var diagnostics: [SettingsDiagnostic] = []
    /// A shim came or went once a file not seen before was read: icons to draw again.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let folder: URL
    /// What each catalog read holds, by hash, kept beside the shims.
    @ObservationIgnored private let record: JSONFile<[String: IconCatalogContents]>
    @ObservationIgnored private var known: [String: IconCatalogContents]
    @ObservationIgnored private var refused: [String: IconFileProblem] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private var icons = TileIcons.none
    @ObservationIgnored private var base = URL(fileURLWithPath: "/")
    /// Observed, so a view drawing a tile's icon draws it again once its file is checked.
    private var shims: [TileIconKey: URL] = [:]
    /// The first reading with every file checked has removed the shims no entry names.
    @ObservationIgnored private var pruned = false

    public init(folder: URL = IconShim.folder) {
        self.folder = folder
        record = JSONFile("catalogs.json", in: folder)
        known = record.load() ?? [:]
    }

    /// Takes `[icons]` as it now reads, its paths relative to `base`: the settings file's folder. True if a
    /// shim came or went.
    @discardableResult
    public func update(_ icons: TileIcons, base: URL) -> Bool {
        self.icons = icons
        self.base = base
        return resolve()
    }

    /// The shim `key`'s file is drawn through, once checked.
    public func shim(for key: TileIconKey) -> URL? {
        shims[key]
    }

    /// What a file holds, as Settings chooses it, or why it is refused.
    public func contents(of url: URL) async throws(IconFileProblem) -> (hash: String, contents: IconCatalogContents) {
        let hash = try IconCatalog.hash(of: url)
        if let contents = known[hash] { return (hash, contents) }
        let contents = try await IconCatalog.read(url)
        remember(contents, hash)
        return (hash, contents)
    }

    /// Where a file chosen in Settings goes, as `[icons]` writes it: named where it is if it is under `folder` —
    /// the settings file's — already, else copied into `icons/` beside it, under its own name, `-2` and on past a
    /// different file of that name. The same file there already, by hash, is named rather than copied again.
    public static func place(_ url: URL, hash: String, in folder: URL) throws -> String {
        let manager = FileManager.default
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let source = url.resolvingSymlinksInPath().standardizedFileURL.path
        if source.hasPrefix(root) { return String(source.dropFirst(root.count)) }
        let icons = folder.appendingPathComponent("icons", isDirectory: true)
        try manager.createDirectory(at: icons, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        for number in 1... {
            let name = stem + (number == 1 ? "" : "-\(number)") + suffix
            let target = icons.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) {
                if (try? IconCatalog.hash(of: target)) == hash { return "icons/" + name }
                continue
            }
            try manager.copyItem(at: url, to: target)
            return "icons/" + name
        }
        fatalError("unreachable")
    }

    /// A shim for one icon of a file `contents(of:)` checked, to draw it before any entry names it.
    public func shim(_ url: URL, hash: String, icon: String) -> URL? {
        do {
            return try IconShim.make(catalog: url, hash: hash, icon: icon, in: folder)
        } catch {
            warn("could not make a shim for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func resolve() -> Bool {
        var shims: [TileIconKey: URL] = [:]
        var problems: [SettingsDiagnostic] = []
        var named: Set<String> = []
        var waiting = false
        for entry in icons.entries {
            guard case .file(let path, let name) = entry.icon else { continue }
            let url = URL(fileURLWithPath: TileIcons.resolve(path, against: base.path))
            do throws(IconFileProblem) {
                let hash = try IconCatalog.hash(of: url)
                named.insert(hash)
                if let problem = refused[hash] { throw problem }
                guard let contents = known[hash] else {
                    read(url, hash)
                    waiting = true
                    continue
                }
                let icon = try contents.icon(named: name)
                do {
                    shims[entry.key] = try IconShim.make(catalog: url, hash: hash, icon: icon, in: folder)
                } catch {
                    problems.append(SettingsDiagnostic(line: entry.line, message: "'\(TileIcons.spell(entry.key))' names \(path), which could not be drawn: \(error.localizedDescription)"))
                }
            } catch {
                problems.append(SettingsDiagnostic(line: entry.line, message: "'\(TileIcons.spell(entry.key))' names \(path), which \(error.reason)"))
            }
        }
        let changed = shims != self.shims
        if changed { self.shims = shims }
        if diagnostics != problems { diagnostics = problems }
        if !waiting, !pruned {
            pruned = true
            IconShim.prune(keeping: Set(shims.values), in: folder)
            if known.keys.contains(where: { !named.contains($0) }) {
                known = known.filter { named.contains($0.key) }
                record.save(known)
            }
        }
        return changed
    }

    /// Reads a catalog not seen before, and resolves again once it is known.
    private func read(_ url: URL, _ hash: String) {
        guard reading.insert(hash).inserted else { return }
        Task {
            do throws(IconFileProblem) {
                remember(try await IconCatalog.read(url), hash)
            } catch {
                refused[hash] = error
            }
            reading.remove(hash)
            if resolve() { onChange?() }
        }
    }

    private func remember(_ contents: IconCatalogContents, _ hash: String) {
        known[hash] = contents
        record.save(known)
    }
}
