import AppKit
import CoreServices
import Dock2Core

/// The apps search answers from ([apps](product/search/apps.md)): the system's application folders and the
/// user's, scanned off the main thread and watched, plus any app that runs from elsewhere. Exact, unlike the
/// Spotlight index, which lists every helper inside the system and every app a build leaves behind.
@MainActor
public final class AppCatalog {
    public struct App: Sendable, Equatable {
        public let ref: AppRef
        public let url: URL
        /// The localised display name first, then the bundle's own name if it differs.
        public let names: [String]
        /// Its build, which an update in place changes.
        public var version: String? = nil
    }

    public nonisolated static let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications"]
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
    }()

    public private(set) var apps: [App] = []
    public var onChange: (() -> Void)?
    private var watcher: FolderWatcher?
    private var usage: [AppRef: (count: Double, last: Date?)] = [:]

    public init() {}

    public func start() {
        rescan()
        watcher = FolderWatcher(paths: Self.roots.map(\.path)) { [weak self] in self?.rescan() }
    }

    private func rescan() {
        Task.detached(priority: .utility) {
            let apps = Self.scan(Self.roots)
            await MainActor.run {
                guard apps != self.apps else { return }
                self.apps = apps
                self.onChange?()
            }
        }
    }

    /// Every `.app` under `roots`, never descending into a bundle — so no helper inside an app — and at most
    /// three folders down, for vendors' folders in `/Applications`. Finder is added: it lives in CoreServices.
    nonisolated static func scan(_ roots: [URL]) -> [App] {
        var found: [App] = []
        var seen: Set<AppRef> = []
        func add(_ url: URL) {
            guard let app = app(at: url), seen.insert(app.ref).inserted else { return }
            found.append(app)
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                // Dot-files only: Safari in /Applications is a symlink flagged hidden.
                if url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                } else if url.pathExtension == "app" {
                    add(url)
                    enumerator.skipDescendants()
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        return found
    }

    public nonisolated static func app(at url: URL) -> App? {
        let bundle = Bundle(url: url)
        var display = FileManager.default.displayName(atPath: url.path)
        if display.hasSuffix(".app") { display.removeLast(4) }
        var names = [display]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.object(forInfoDictionaryKey: key) as? String, !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return App(ref: AppRef(bundleIdentifier: bundle?.bundleIdentifier, path: url.path), url: url, names: names,
                   version: version(of: url))
    }

    /// From the Info.plist on disk: `Bundle` keeps what it first read, through an update.
    public nonisolated static func version(of url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    /// The system's own record of use (`kMDItemUseCount`, `kMDItemLastUsedDate`), read once per app: the
    /// apps' last tiebreak.
    public func systemUse(_ app: App) -> (count: Double, last: Date?) {
        if let cached = usage[app.ref] { return cached }
        var value: (Double, Date?) = (0, nil)
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, app.url as CFURL) {
            // kMDItemUseCount has no constant in the SDK: it is named.
            let count = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.doubleValue ?? 0
            let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            value = (count, last)
        }
        usage[app.ref] = value
        return value
    }
}
