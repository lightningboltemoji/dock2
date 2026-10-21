import Dock2System

/// `dock2 --restore`: gives back what a dock2 that is no longer running took over. What the system would
/// not take back is kept, and the exit is 1: running it again tries again.
func restore() -> Int32 {
    let takeovers = Takeovers()
    let held = takeovers.journal.entries.keys.sorted()
    let kept = takeovers.releaseAll()
    if !takeovers.journal.unknown.isEmpty {
        warn("kept what a newer dock2 took over — \(takeovers.journal.unknown.keys.sorted().joined(separator: ", ")) — for its own --restore")
    }
    guard kept.isEmpty else {
        warn("could not give back \(kept.map(\.description).joined(separator: ", ")); run dock2 --restore again")
        return 1
    }
    note(held.isEmpty ? "nothing to give back: dock2 holds nothing" : "gave back \(held.map(\.description).joined(separator: ", "))")
    return 0
}
