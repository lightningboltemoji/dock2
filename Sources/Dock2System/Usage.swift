import Dock2Core
import Foundation
import Observation

/// What dock2 has opened, how often and how lately: the apps' and commands' ranking signal, kept in
/// `usage.json`.
@MainActor
public final class Usage {
    public struct Record: Codable, Sendable {
        public var count: Int
        public var last: Date
    }

    private let file = JSONFile<[String: Record]>("usage.json")
    private var records: [String: Record]

    public init() {
        records = file.load() ?? [:]
    }

    public func record(_ id: String, at date: Date = Date()) {
        var entry = records[id] ?? Record(count: 0, last: date)
        entry.count += 1
        entry.last = date
        records[id] = entry
        file.save(records)
    }

    /// Uses, worth less the longer ago the last one was: 0 for never.
    public func frecency(_ id: String, now: Date = Date()) -> Double {
        guard let entry = records[id] else { return 0 }
        let days = max(0, now.timeIntervalSince(entry.last) / 86_400)
        return Double(entry.count) / (1 + days / 7)
    }
}

/// The learned picks, kept in `picks.json`.
@MainActor
@Observable
public final class PicksStore {
    @ObservationIgnored private let file = JSONFile<LearnedPicks>("picks.json")
    public private(set) var picks: LearnedPicks

    public init() {
        picks = file.load() ?? LearnedPicks()
    }

    public func update(_ change: (inout LearnedPicks) -> Void) {
        change(&picks)
        file.save(picks)
    }
}
