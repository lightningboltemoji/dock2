import Foundation

/// What a tile stands for.
public enum TileKind: Hashable, Sendable {
    /// Always first; it opens Files, and Finder itself with ⌥.
    case finder
    case app(AppRef)
    /// A plugin's live tile, by plugin and tile identifier.
    case plugin(String)
    /// A minimised window, by the number dock2 gave the system Dock's item for it.
    case window(Int)

    /// The app behind the tile, if it is one.
    public var app: AppRef? {
        switch self {
        case .finder: .finder
        case .app(let app): app
        case .plugin, .window: nil
        }
    }
}

/// The groups a separator opens.
public enum DockGroup: Hashable, Sendable {
    case plugins
    case windows
}

/// One position along the dock, left to right.
public enum DockSlot: Hashable, Sendable {
    case tile(TileKind)
    case separator(DockGroup)

    public var tile: TileKind? {
        if case .tile(let kind) = self { return kind }
        return nil
    }
}

/// Which tiles the dock shows, in what order ([dock](../../.agents/product/dock.md#tiles)).
public enum DockModel {
    /// `running` is in the order the apps started, and those not pinned follow the pinned ones with no
    /// separator, as on the system Dock; `windows`, the minimised windows, in the order they were minimised.
    /// The `sidelined` apps are on the puck instead (`sideline`), pinned or not.
    public static func compose(pinned: [AppRef], running: [AppRef], showRunning: Bool = true, sidelined: [AppRef] = [],
                               pluginTiles: [String] = [], windows: [Int] = []) -> [DockSlot] {
        var slots: [DockSlot] = [.tile(.finder)]
        var present = Set(sidelined).union([.finder])
        for app in pinned where present.insert(app).inserted {
            slots.append(.tile(.app(app)))
        }

        if showRunning {
            for app in running where present.insert(app).inserted {
                slots.append(.tile(.app(app)))
            }
        }

        if !pluginTiles.isEmpty {
            slots.append(.separator(.plugins))
            slots += pluginTiles.map { .tile(.plugin($0)) }
        }

        if !windows.isEmpty {
            slots.append(.separator(.windows))
            slots += windows.map { .tile(.window($0)) }
        }
        return slots
    }

    /// The puck's apps: the sidelined ones running, in the list's order whatever order they started in, whether
    /// or not the running apps show. Finder is never sidelined.
    public static func sideline(_ sidelined: [AppRef], running: [AppRef]) -> [AppRef] {
        let running = Set(running)
        var seen: Set<AppRef> = [.finder]
        return sidelined.filter { running.contains($0) && seen.insert($0).inserted }
    }

    /// The pinned apps on show: those `drawable`, once each. One that is not stays pinned, out of sight.
    public static func shown(_ pinned: [AppRef], drawable: (AppRef) -> Bool) -> [AppRef] {
        var seen = Set<AppRef>()
        return pinned.filter { drawable($0) && seen.insert($0).inserted }
    }

    /// `pinned` with `new` placed at a drag's `gap` — before the gap-th app on show other than `new`, or at
    /// the end when nil or past them all — an app already pinned moving there; Finder is never pinned.
    public static func pinning(_ new: [AppRef], atGap gap: Int?, in pinned: [AppRef], drawable: (AppRef) -> Bool) -> [AppRef] {
        let moving = Set(new)
        let others = shown(pinned, drawable: drawable).filter { !moving.contains($0) }
        var result = pinned.filter { !moving.contains($0) }
        let index = gap.flatMap { others.indices.contains($0) ? result.firstIndex(of: others[$0]) : nil } ?? result.count
        result.insert(contentsOf: new.filter { $0 != .finder }, at: index)
        return result
    }

    /// The tiles ⌘1–⌘9 and the tile numbers reach: the first nine, counted from the left, a nil — a
    /// separator, or a drag's gap — skipped. Index `n` holds the index of tile `n + 1` in `tiles`.
    public static func numbered(_ tiles: [TileKind?]) -> [Int] {
        Array(tiles.indices.filter { tiles[$0] != nil }.prefix(9))
    }
}

/// The apps placed by choice: kept in the dock, or sidelined. An app is pinned, sidelined or neither, so each
/// move takes it out of the other list.
public struct DockChoices: Sendable, Equatable {
    public var pinned: [AppRef]
    public var sidelined: [AppRef]

    public init(pinned: [AppRef], sidelined: [AppRef]) {
        (self.pinned, self.sidelined) = (pinned, sidelined)
    }

    /// Keeps `apps` in the dock, at a drag's `gap` (`DockModel.pinning`) or last.
    public mutating func pin(_ apps: [AppRef], atGap gap: Int? = nil, drawable: (AppRef) -> Bool = { _ in true }) {
        pinned = DockModel.pinning(apps, atGap: gap, in: pinned, drawable: drawable)
        sidelined.removeAll(where: apps.contains)
    }

    public mutating func unpin(_ app: AppRef) {
        pinned.removeAll { $0 == app }
    }

    /// Sidelines `app`, last on the puck.
    public mutating func sideline(_ app: AppRef) {
        guard app != .finder else { return }
        pinned.removeAll { $0 == app }
        if !sidelined.contains(app) { sidelined.append(app) }
    }

    /// Back among the running apps.
    public mutating func unsideline(_ app: AppRef) {
        sidelined.removeAll { $0 == app }
    }
}
