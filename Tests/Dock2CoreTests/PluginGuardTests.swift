import Dock2Core
import Foundation
import Testing

/// Against a folder of its own: `granted/` holds a note, a link to a file outside and one to a folder outside,
/// and a dangling link that points outside.
@Suite struct PathGuardTests {
    let root: URL
    let granted: URL
    let outside: URL

    init() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: PathGuard.realpathOf(fm.temporaryDirectory.path)).appendingPathComponent("dock2-guard-\(UUID().uuidString)")
        granted = root.appendingPathComponent("granted")
        outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: granted.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: granted.appendingPathComponent("note.txt"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(atPath: granted.appendingPathComponent("leak.txt").path, withDestinationPath: outside.appendingPathComponent("secret.txt").path)
        try fm.createSymbolicLink(atPath: granted.appendingPathComponent("door").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: granted.appendingPathComponent("trap").path, withDestinationPath: outside.appendingPathComponent("new.txt").path)
        try fm.createSymbolicLink(atPath: granted.appendingPathComponent("inner").path, withDestinationPath: "sub")
    }

    var guarded: PathGuard { PathGuard(folders: [granted.path]) }

    @Test func aPathInsideIsReachedAsTheFileSystemReachesIt() throws {
        #expect(try guarded.reach(granted.appendingPathComponent("note.txt").path) == granted.appendingPathComponent("note.txt").path)
        #expect(try guarded.reach(granted.path) == granted.path)
        // A link that stays inside is followed.
        #expect(try guarded.reach(granted.path + "/inner") == granted.path + "/sub")
        // Not there yet: its deepest folder resolved, then the rest, for a write.
        #expect(try guarded.reach(granted.path + "/inner/new/deeper.txt") == granted.path + "/sub/new/deeper.txt")
        #expect(try guarded.reach(granted.path + "/./note.txt") == granted.path + "/note.txt")
    }

    @Test func linksOutAndClimbingAreRefused() {
        #expect(throws: PathGuard.Refusal.outside(granted.path + "/leak.txt")) { try guarded.reach(granted.path + "/leak.txt") }
        #expect(throws: PathGuard.Refusal.outside(granted.path + "/door/secret.txt")) { try guarded.reach(granted.path + "/door/secret.txt") }
        #expect(throws: PathGuard.Refusal.outside(granted.path + "/door/new.txt")) { try guarded.reach(granted.path + "/door/new.txt") }
        // A dangling link: writing to it would create the file it points at, outside.
        #expect(throws: PathGuard.Refusal.outside(granted.path + "/trap")) { try guarded.reach(granted.path + "/trap") }
        #expect(throws: PathGuard.Refusal.climbs(granted.path + "/sub/../note.txt")) { try guarded.reach(granted.path + "/sub/../note.txt") }
        #expect(throws: PathGuard.Refusal.notAbsolute("note.txt")) { try guarded.reach("note.txt") }
        #expect(throws: PathGuard.Refusal.outside(outside.path)) { try guarded.reach(outside.path) }
        // A sibling whose name starts the same is not inside.
        #expect(throws: (any Error).self) { try PathGuard(folders: [granted.path]).reach(granted.path + "-twin/x") }
        #expect(throws: PathGuard.Refusal.noFolders) { try PathGuard(folders: []).reach(granted.path) }
    }

    /// A granted folder is itself resolved: one spelled through a link is reached where it leads.
    @Test func aGrantedFolderSpelledThroughALinkGrantsWhereItLeads() throws {
        let link = root.appendingPathComponent("granted-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: granted.path)
        #expect(try PathGuard(folders: [link.path]).reach(link.path + "/note.txt") == granted.path + "/note.txt")
        #expect(PathGuard(folders: [root.path + "/missing"]).roots.isEmpty)
    }
}

extension PathGuard {
    /// The test's own temporary folder, as realpath spells it: `/var` is a link to `/private/var`.
    static func realpathOf(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

@Suite struct CommandGuardTests {

    @Test func slotsFillTheDeclaredArguments() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: PathGuard.realpathOf(fm.temporaryDirectory.path)).appendingPathComponent("dock2-cmd-\(UUID().uuidString)")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let folders = PathGuard(folders: [repo.path])
        let status = RunCommand(id: "status", program: "/usr/bin/git", arguments: ["-C", "{folder}", "status", "--porcelain"].map(RunCommand.Argument.init))
        let invocation = try CommandGuard.invocation(of: status, values: ["folder": repo.path], arguments: nil, folders: folders)
        #expect(invocation == .init(program: "/usr/bin/git", arguments: ["-C", repo.path, "status", "--porcelain"], directory: repo.path))

        let grep = RunCommand(id: "grep", program: "/usr/bin/grep", arguments: ["-rn", "{text}", "{path}"].map(RunCommand.Argument.init))
        // One argument each, whatever it holds: no shell reads it.
        let found = try CommandGuard.invocation(of: grep, values: ["text": "a; rm -rf ~", "path": repo.path], arguments: nil, folders: folders)
        #expect(found.arguments == ["-rn", "a; rm -rf ~", repo.path] && found.directory == nil)
        #expect(throws: CommandGuard.Refusal.dash(.text)) { try CommandGuard.invocation(of: grep, values: ["text": "--exec=x", "path": repo.path], arguments: nil, folders: folders) }
        #expect(throws: CommandGuard.Refusal.missing(.path)) { try CommandGuard.invocation(of: grep, values: ["text": "a"], arguments: nil, folders: folders) }
        #expect(throws: CommandGuard.Refusal.path(.path, .outside("/etc"))) {
            try CommandGuard.invocation(of: grep, values: ["text": "a", "path": "/etc"], arguments: nil, folders: folders)
        }
        #expect(throws: CommandGuard.Refusal.arguments) { try CommandGuard.invocation(of: grep, values: [:], arguments: ["-v"], folders: folders) }
        #expect(throws: CommandGuard.Refusal.nul) { try CommandGuard.invocation(of: grep, values: ["text": "a\0b", "path": repo.path], arguments: nil, folders: folders) }
    }

    /// The escape takes the plugin's arguments as they are, `-` and all; still no shell, still no NUL.
    @Test func aCommandWithAnyArgumentsTakesThemAsTheyAre() throws {
        let shell = RunCommand(id: "shell", program: "/bin/zsh", arguments: nil)
        let none = PathGuard(folders: [])
        #expect(try CommandGuard.invocation(of: shell, values: [:], arguments: ["-c", "echo hi"], folders: none).arguments == ["-c", "echo hi"])
        #expect(throws: CommandGuard.Refusal.noArguments) { try CommandGuard.invocation(of: shell, values: [:], arguments: nil, folders: none) }
        #expect(throws: CommandGuard.Refusal.nul) { try CommandGuard.invocation(of: shell, values: [:], arguments: ["\0"], folders: none) }
    }
}

@Suite struct HostPortTests {
    @Test func spellingsAndSettings() {
        #expect(HostPort("LocalHost:11434") == HostPort(host: "localhost", port: 11434))
        #expect(HostPort("[::1]:8080")?.spelled == "[::1]:8080")
        #expect(HostPort("localhost") == nil && HostPort("localhost:0") == nil && HostPort("host:99999") == nil)
        #expect(HostPort(setting: "http://nas.local:5000/api") == HostPort(host: "nas.local", port: 5000))
        #expect(HostPort(setting: "http://nas.local") == HostPort(host: "nas.local", port: 80))
        #expect(HostPort(setting: "nas.local:5000") == HostPort(host: "nas.local", port: 5000))
        #expect(HostPort(setting: "http://nas.local:70000/") == nil)
    }

    @Test func localIsThisMacOrTheLocalNetwork() {
        for local in ["localhost:1", "nas.local:1", "nas:1", "127.0.0.1:1", "10.1.2.3:1", "172.20.0.1:1", "192.168.1.9:1", "169.254.0.5:1",
                      "[::1]:1", "[fe80::1]:1", "[fd00::5]:1", "[::ffff:192.168.1.2]:1"] {
            #expect(HostPort(local)?.isLocal == true, "\(local)")
        }
        for remote in ["example.com:80", "8.8.8.8:53", "172.32.0.1:1", "[2001:4860::8888]:1", "[::ffff:8.8.8.8]:1"] {
            #expect(HostPort(remote)?.isLocal == false, "\(remote)")
        }
    }
}
