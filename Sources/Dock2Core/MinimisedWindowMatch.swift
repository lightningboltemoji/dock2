import Foundation

/// Which app window each of the system Dock's minimised items is. The Dock gives an item only the title
/// its window had when minimised, so an item is matched once, to the minimised window of that title no
/// other item has that was minimised last — of a group of tabs, the one on show — and keeps it while both last.
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
        public init(id: Int, title: String, order: Int) { (self.id, self.title, self.order) = (id, title, order) }
    }

    /// How long an item waits for its window before it is shown without one. The Dock lists an item as the
    /// genie starts and the app says the window is minimised as it ends, half a second later.
    public static let patience: TimeInterval = 2

    /// Each matched item's window, by id.
    public private(set) var windows: [Int: Int] = [:]
    /// When each unmatched item began waiting for its window.
    private var waiting: [Int: Date] = [:]

    public init() {}

    /// Matches `items`, in the Dock's order, among the `minimised` windows. An item with no window to match
    /// — its window's minimising not yet heard — stays unmatched until a later update finds one.
    public mutating func update(items: [Item], minimised: [Window], at now: Date = Date()) {
        let present = Set(minimised.map(\.id))
        windows = windows.filter { item, window in items.contains { $0.id == item } && present.contains(window) }
        var taken = Set(windows.values)
        for item in items where windows[item.id] == nil {
            guard let window = minimised.filter({ $0.title == item.title && !taken.contains($0.id) }).max(by: { $0.order < $1.order })
            else { continue }
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
