import Darwin
import Dock2Core
@testable import Dock2Plugins
import Foundation
import Testing

/// The test guest's commands, run for real: `/bin/echo`, `/bin/sh` declared with a `{folder}`, `/bin/sleep`
/// with half a second, `/usr/bin/yes` with three, `/bin/ls` said to be signed by a team it is not, `/bin/cat`.
@MainActor
@Suite(.serialized) struct PluginRunTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-run-\(UUID().uuidString)", isDirectory: true)
    let id = TestHost.id

    /// A folder for its folder setting, as realpath spells it: the program sees where the links lead.
    func folder() throws -> String {
        let folder = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let resolved = realpath(folder.path, nil) else { return folder.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func exited(_ recorder: Recorder, _ request: String) -> String? {
        recorder.toasts.first { $0.hasPrefix("exited \(request) ") }
    }

    /// A slot is one argument, whatever it holds: no shell reads it.
    @Test func aCommandRunsItsSlotsAsArguments() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "run-echo"), to: id)
        try await TestHost.settle(until: { exited(recorder, "echo") != nil }, seconds: 3)
        #expect(exited(recorder, "echo") == "exited echo Some(0) None truncated=false timedOut=false: hi; rm -rf ~")
        #expect(host.resources.isIdle(id))
    }

    @Test func aSlotStartingWithADashOrOutsideItsFoldersIsRefused() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory, settings: ["folder": try folder()])
        host.send(.command(id: "run-dash"), to: id)
        host.send(.command(id: "run-outside"), to: id)
        try await TestHost.settle(until: { recorder.toasts.count >= 3 }, seconds: 3)
        #expect(recorder.toasts.contains("error: echo: its {text} starts with -, which a program would read as an option"))
        #expect(recorder.toasts.contains("error: where: its {folder}: /etc is not inside a folder it was granted"))
    }

    /// In the folder its slot names, with four variables of dock2's and nothing else.
    @Test func itRunsInItsFolderWithAMinimalEnvironment() async throws {
        let recorder = Recorder(), folder = try folder(), host = TestHost.make(recorder, in: directory, settings: ["folder": folder])
        host.send(.command(id: "run-where"), to: id)
        try await TestHost.settle(until: { exited(recorder, "where") != nil }, seconds: 3)
        let said = try #require(exited(recorder, "where")).components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        let lines = said.split(separator: "\n")
        #expect(lines.first.map(String.init) == folder, "\(recorder.toasts)")
        // What `sh` adds of its own besides.
        let names = Set((lines.dropFirst().first ?? "").split(separator: " ").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(names.isSubset(of: ["PATH", "HOME", "LANG", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD"]) && names.isSuperset(of: ["PATH", "HOME", "LANG", "TMPDIR"]))
    }

    @Test func itsTimeRunsOutAndItIsEnded() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "run-sleep"), to: id)
        try await TestHost.settle(until: { exited(recorder, "sleep") != nil }, seconds: 3)
        #expect(exited(recorder, "sleep") == "exited sleep None Some(15) truncated=false timedOut=true: ")
    }

    /// Cancelled before it has even spawned, it is ended as it does; the plugin still hears how.
    @Test func aPluginEndsWhatItRan() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "run-sleep"), to: id)
        host.send(.command(id: "cancel-sleep"), to: id)
        try await TestHost.settle(until: { exited(recorder, "sleep") != nil }, seconds: 3)
        #expect(exited(recorder, "sleep") == "exited sleep None Some(15) truncated=false timedOut=false: ")
    }

    /// Revoked, it is ended and the plugin hears nothing more of it.
    @Test func revokingRunEndsWhatRuns() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        let held = { !host.resources.keys(.process, of: id).isEmpty }
        host.send(.command(id: "run-yes"), to: id)
        // Its first event starts the instance; revoked before then, `run` is refused rather than ended.
        try await TestHost.settle(until: held, seconds: 5)
        try #require(held())
        host.setGranted(id, .run, false)
        #expect(host.resources.isIdle(id))
        try await TestHost.settle(until: { recorder.toasts.contains("error: run was revoked") }, seconds: 3)
        #expect(recorder.toasts.contains("error: run was revoked") && exited(recorder, "yes") == nil)
    }

    /// Past what dock2 carries, the rest is read and dropped, and the plugin is told.
    @Test func outputPastTheLimitIsDropped() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "run-yes"), to: id)
        try await TestHost.settle(until: { exited(recorder, "yes") != nil }, seconds: 6)
        #expect(exited(recorder, "yes") == "exited yes None Some(15) truncated=true timedOut=true: \(PluginProcess.outputLimit) bytes")
    }

    @Test func aProgramNotSignedByItsTeamIsNotRun() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "run-signed"), to: id)
        try await TestHost.settle(until: { recorder.toasts.contains { $0.hasPrefix("error") } }, seconds: 3)
        #expect(recorder.toasts.contains("error: signed: /bin/ls is not signed by ABCDE12345"))
    }

    @Test func whatThePluginGivesItReadsOnItsInput() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "run-cat"), to: id)
        try await TestHost.settle(until: { exited(recorder, "cat") != nil }, seconds: 3)
        #expect(exited(recorder, "cat") == "exited cat Some(0) None truncated=false timedOut=false: piped in")
    }

    /// The program answers to macOS for itself, never with what dock2 — here, the test's terminal — was granted.
    @Test func theProgramIsResponsibleForItself() async throws {
        let ended = Box(false)
        let process = try PluginProcess.spawn(.init(program: "/bin/sleep", arguments: ["5"], directory: nil), team: nil, stdin: nil,
                                              onOutput: { _, _ in }, onExit: { _, _ in ended.value = true })
        #expect(Disclaim.responsible(for: process.pid) == process.pid)
        process.terminate()
        try await TestHost.settle(until: { ended.value }, seconds: 3)
        #expect(ended.value && kill(process.pid, 0) != 0)
    }
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
