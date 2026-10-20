import AppKit
import Dock2Shell
import os

programName = "dock2"

let usage = """
    usage: dock2              run dock2 in place of the system Dock
           dock2 --restore    put the system Dock back, if a dock2 that is no longer running left it hidden
           dock2 --version
    """

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    break
case "--version":
    note(dock2Version)
    exit(0)
case "-h", "--help":
    note(usage)
    exit(0)
case Guard.flag:
    guard arguments.count == 2, let parent = pid_t(arguments[1]) else {
        warn("\(Guard.flag) takes the pid to watch")
        exit(2)
    }
    Guard.run(parent: parent)
case "--restore":
    guard let lock = InstanceLock.claim(waiting: 2) else {
        warn("dock2 is running\(InstanceLock.holder.map { " as pid \($0)" } ?? ""); quit it and it restores the Dock itself")
        exit(1)
    }
    let restored = withExtendedLifetime(lock) { Suppressor.restore() }
    note(restored ? "restored the system Dock" : "nothing to restore: the system Dock is not hidden by dock2")
    exit(0)
default:
    warn("unknown argument \(arguments[0])")
    note(usage)
    exit(2)
}

systemLog = Logger(subsystem: "zip.tanner.dock2", category: "dock")
// Waits a moment, in case a guard is still restoring for a dock2 that just quit.
guard let lock = InstanceLock.claim(waiting: 2) else {
    warn("already running\(InstanceLock.holder.map { " as pid \($0)" } ?? "")")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = DockController(lock: lock)
app.delegate = controller
app.run()
