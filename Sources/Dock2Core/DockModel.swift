import Foundation

/// What a tile stands for.
public enum TileKind: Hashable, Sendable {
    /// Always first; it opens Files, and Finder itself with ⌥.
    case finder
    case app(AppRef)
    /// Stands in for a selected search result whose app is not on the dock.
    case temporary(AppRef)
    /// A plugin's live tile, by plugin and tile identifier.
    case plugin(String)
    /// A minimised window, by the number dock2 gave the system Dock's item for it.
    case window(Int)

    /// The app behind the tile, if it is one.
    public var app: AppRef? {
        switch self {
        case .finder: .finder
        case .app(let app), .temporary(let app): app
        case .plugin, .window: nil
        }
    }
}

/// The groups a separator opens.
public enum DockGroup: Hashable, Sendable {
    case running
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
    /// `running` is in the order the apps started; `temporary`, an app selected in search, is shown while
    /// it is; `windows`, the minimised windows, in the order they were minimised.
    public static func compose(pinned: [AppRef], running: [AppRef], showRunning: Bool = true,
                               temporary: AppRef? = nil, pluginTiles: [String] = [], windows: [Int] = []) -> [DockSlot] {
        var slots: [DockSlot] = [.tile(.finder)]
        var present: Set<AppRef> = [.finder]
        for app in pinned where present.insert(app).inserted {
            slots.append(.tile(.app(app)))
        }

        var group: [DockSlot] = []
        if showRunning {
            for app in running where present.insert(app).inserted {
                group.append(.tile(.app(app)))
            }
        }
        if let temporary, present.insert(temporary).inserted {
            group.append(.tile(.temporary(temporary)))
        }
        if !group.isEmpty {
            slots.append(.separator(.running))
            slots += group
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

    /// The tiles ⌘1–⌘9 and the number badges reach: the first nine, counted from the left, separators
    /// skipped. Index `n` holds the slot index of tile `n + 1`.
    public static func numbered(_ slots: [DockSlot]) -> [Int] {
        Array(slots.indices.filter { slots[$0].tile != nil }.prefix(9))
    }
}
