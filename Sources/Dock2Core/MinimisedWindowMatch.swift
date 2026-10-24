import Foundation

/// Which app window each of the system Dock's minimised items is. The Dock gives an item only the title its
/// window had when minimised, so each item, in the Dock's order, is matched once to the window of that title
/// minimised first of those no other item has, minimised within `patience` of the item's first showing.
public struct MinimisedWindowMatch: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var id: Int
        public var title: String
        public init(id: Int, title: String) { (self.id, self.title) = (id, title) }
    }

    public struct Window: Sendable, Equatable {
        public var id: Int
        public var title: String
        /// Higher for a window minimised later.
        public var order: Int
        public var minimisedAt: Date
        public init(id: Int, title: String, order: Int, minimisedAt: Date) {
            (self.id, self.title, self.order, self.minimisedAt) = (id, title, order, minimisedAt)
        }
    }

    /// How far apart an item's showing and its window's minimising can be, and how long an item waits for
    /// its window before it is shown without one. The two land together, or half a second apart.
    public static let patience: TimeInterval = 2

    /// Each matched item's window, by id.
    public private(set) var windows: [Int: Int] = [:]
    /// When each item was first shown.
    private var seen: [Int: Date] = [:]
    /// When each unmatched item began waiting for its window.
    private var waiting: [Int: Date] = [:]

    public init() {}

    /// Matches `items`, in the Dock's order, among the `minimised` windows that can have an item — a group of
    /// tabs' hidden tabs never do. An item with no window to match stays unmatched until a later update finds one.
    public mutating func update(items: [Item], minimised: [Window], at now: Date = Date()) {
        let present = Set(minimised.map(\.id))
        windows = windows.filter { item, window in items.contains { $0.id == item } && present.contains(window) }
        seen = Dictionary(uniqueKeysWithValues: items.map { ($0.id, seen[$0.id] ?? now) })
        var taken = Set(windows.values)
        for item in items where windows[item.id] == nil {
            let since = seen[item.id] ?? now
            guard let window = minimised.filter({
                $0.title == item.title && !taken.contains($0.id) && abs($0.minimisedAt.timeIntervalSince(since)) <= Self.patience
            }).min(by: { $0.order < $1.order }) else { continue }
            windows[item.id] = window.id
            taken.insert(window.id)
        }
        waiting = Dictionary(uniqueKeysWithValues: items.filter { windows[$0.id] == nil }.map { ($0.id, waiting[$0.id] ?? now) })
    }

    /// Whether an item is shown: matched, or unmatched for `patience`, when its window is not coming.
    public func isShown(_ item: Int, at now: Date = Date()) -> Bool {
        guard let since = waiting[item] else { return true }
        return now.timeIntervalSince(since) >= Self.patience
    }

    /// The next moment after `now` an item still waiting is shown without its window.
    public func nextDeadline(after now: Date) -> Date? {
        waiting.values.map { $0.addingTimeInterval(Self.patience) }.filter { $0 > now }.min()
    }
}
