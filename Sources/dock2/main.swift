import AppKit
import Dock2Shell
import Dock2System
import os

programName = "dock2"

let usage = """
    usage: dock2              run dock2 in place of the system Dock
           dock2 --restore    give back the system Dock and everything else a dock2 that is no longer running took over
           dock2 --version
           dock2 plugin list
           dock2 plugin install <folder> [--yes]
           dock2 plugin dev <folder> [--yes]      install it, and again each time it is rebuilt
           dock2 plugin remove <id>
    """

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    break
case "--version":
    note(Dock2Identity.version)
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
case "plugin":
    exit(MainActor.assumeIsolated { PluginCommand(usage: usage).run(Array(arguments.dropFirst())) })
case "--restore":
    guard let lock = InstanceLock.claim(waiting: 2) else {
        warn("dock2 is running\(InstanceLock.holder.map { " as pid \($0)" } ?? ""); quit it and it gives everything back itself")
        exit(1)
    }
    exit(withExtendedLifetime(lock) { restore() })
default:
    // LaunchServices adds `-psn_…` to an app it opens on some macOS versions.
    guard arguments[0].hasPrefix("-psn_") else {
        warn("unknown argument \(arguments[0])")
        note(usage)
        exit(2)
    }
}

systemLog = Logger(subsystem: Dock2Identity.bundleIdentifier, category: "dock")
// Waits a moment, in case a guard is still giving things back for a dock2 that just quit.
guard let lock = InstanceLock.claim(waiting: 2) else {
    warn("already running\(InstanceLock.holder.map { " as pid \($0)" } ?? "")")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController(lock: lock)
app.delegate = controller
app.run()
