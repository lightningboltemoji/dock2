import AppKit
import Dock2Core

/// What is playing ([first-party](product/plugins/first-party.md#now-playing)), read by a helper
/// `/usr/bin/perl` hosts (`Helpers/now-playing`) and controlled from here. MediaRemote is private: this
/// file and the helper are the only places that touch it.
@MainActor
public final class NowPlaying {
    public private(set) var info: NowPlayingInfo?
    private var observers: [UUID: (NowPlayingInfo?) -> Void] = [:]
    private var process: Process?
    private var input: Pipe?
    private var pending = Data()
    private var artwork: Data?
    private var restarts = 0
    private let helpers: URL?

    public init(helpers: URL? = NowPlaying.helperDirectory) {
        self.helpers = helpers
    }

    /// Inside the bundle, `Resources/Helpers`; run from `.build`, what `make helpers` put beside it.
    public static var helperDirectory: URL? {
        if Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier { return Bundle.main.resourceURL?.appendingPathComponent("Helpers") }
        return Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("helpers")
    }

    public struct Observation {
        fileprivate let cancel: () -> Void
        public func end() { cancel() }
    }

    /// Hears every change, starting with the state now. The helper runs while anyone listens.
    public func observe(_ observer: @escaping (NowPlayingInfo?) -> Void) -> Observation {
        let id = UUID()
        observers[id] = observer
        if process == nil { start() } else { observer(info) }
        return Observation { [weak self] in
            MainActor.assumeIsolated {
                self?.observers[id] = nil
                if self?.observers.isEmpty == true { self?.stop() }
            }
        }
    }

    private func start() {
        guard let helpers else { return }
        let script = helpers.appendingPathComponent("nowplaying.pl"), library = helpers.appendingPathComponent("libdock2nowplaying.dylib")
        guard FileManager.default.fileExists(atPath: library.path) else {
            warn("now playing: no helper at \(helpers.path)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        // Held open for the helper's life: when dock2 goes, so does it.
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(status) } }
        }
        do {
            try process.run()
            self.process = process
            self.input = input
        } catch {
            warn("now playing: the helper did not start: \(error.localizedDescription)")
        }
    }

    private func stop() {
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        process.terminate()
    }

    private func ended(_ status: Int32) {
        guard process != nil else { return }
        process = nil
        warn("now playing: the helper ended (\(status))")
        // Back a few times, with a pause between: a crash is not a reason to stop for good.
        guard restarts < 3, !observers.isEmpty else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { if self?.process == nil, self?.observers.isEmpty == false { self?.start() } }
        }
    }

    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            parse(Data(line))
        }
    }

    private func parse(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if object["artwork"] is NSNull { artwork = nil }
        if let encoded = object["artwork"] as? String { artwork = Data(base64Encoded: encoded) }
        if object["empty"] as? Bool == true {
            info = nil
        } else {
            info = NowPlayingInfo(title: object["title"] as? String, artist: object["artist"] as? String, album: object["album"] as? String,
                                  playing: object["playing"] as? Bool ?? false, duration: object["duration"] as? Double,
                                  elapsed: object["elapsed"] as? Double, timestamp: object["timestamp"] as? Double, artwork: artwork,
                                  app: (object["app"] as? String).map(Self.name(of:)))
        }
        for observer in observers.values { observer(info) }
    }

    /// "Music", not "com.apple.Music": the app playing is running, and says its own name; else LaunchServices'.
    private static func name(of bundle: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            } ?? bundle
    }

    // MARK: - Commands

    private static let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

    /// play, pause, toggle, next, previous; seek to `seconds`. To whatever app is playing.
    public func send(_ command: String, seconds: Double? = nil) {
        guard let library = Self.mediaRemote else { return }
        if command == "seek", let seconds {
            typealias Seek = @convention(c) (Double) -> Void
            guard let symbol = dlsym(library, "MRMediaRemoteSetElapsedTime") else { return }
            unsafeBitCast(symbol, to: Seek.self)(seconds)
            return
        }
        let codes = ["play": 0, "pause": 1, "toggle": 2, "next": 4, "previous": 5]
        guard let code = codes[command], let symbol = dlsym(library, "MRMediaRemoteSendCommand") else { return }
        typealias Send = @convention(c) (Int32, CFDictionary?) -> Bool
        _ = unsafeBitCast(symbol, to: Send.self)(Int32(code), nil)
    }
}
