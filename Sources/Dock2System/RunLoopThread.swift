import Foundation

/// A thread running a run loop of its own, for Accessibility's calls and notifications: the process asked
/// may hang, and holds up only this thread. It runs as long as dock2 does.
final class RunLoopThread: @unchecked Sendable {
    private(set) var runLoop: CFRunLoop!

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // A source that never fires keeps the run loop running while nothing else is on it.
            var context = CFRunLoopSourceContext()
            CFRunLoopAddSource(runLoop, CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    /// Runs `work` on the thread. Sendable, so that work written in a main-actor method is not taken to be
    /// the main actor's.
    func perform(_ work: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `work` on the thread every `interval`, first one `interval` from now, until the timer is
    /// invalidated.
    func every(_ interval: TimeInterval, _ work: @escaping @Sendable () -> Void) -> CFRunLoopTimer {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0) { _ in work() }!
        CFRunLoopTimerSetTolerance(timer, 0.1)
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        return timer
    }
}
