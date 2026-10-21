import Dock2System
import Foundation

/// Keeps a guard process watching dock2 (IMPLEMENTATION.md §4): starts one, and another whenever it dies,
/// at most five times a minute.
@MainActor
final class GuardKeeper {
    private var watch: DispatchSourceProcess?
    private var starts: [Date] = []
    private var stopped = false

    func start() {
        // A guard that dies as soon as it starts is not worth restarting forever.
        starts = starts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        guard starts.count <= 5, let pid = Guard.spawn() else {
            warn("running without a guard: if dock2 crashes, `dock2 --restore` or its next launch gives back what it took over")
            return
        }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                waitpid(pid, nil, WNOHANG)
                guard let self, !self.stopped else { return }
                warn("the guard (pid \(pid)) exited; starting another")
                self.watch?.cancel()
                self.start()
            }
        }
        watch.resume()
        self.watch = watch
    }

    /// dock2 is quitting and gives everything back itself: the guard's exit is expected now.
    func stop() {
        stopped = true
        watch?.cancel()
    }
}
