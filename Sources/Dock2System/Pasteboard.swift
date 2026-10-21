import AppKit
import CryptoKit
import Dock2Core

/// A copy worth keeping, read off the pasteboard.
public struct ClipCapture: Sendable {
    public let entry: ClipEntry
    public let data: [String: Data]
}

/// The general pasteboard, watched ([clipboard](product/clipboard.md#what-is-kept)): macOS says nothing when it
/// changes, so its change count is looked at four times a second, and read when it moves.
@MainActor
public final class PasteboardWatcher {
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastSeen: Int
    /// Change counts dock2's own writes made: not copies of the user's.
    private var ownWrites: Set<Int> = []
    public var ignoredApps: () -> Set<String> = { Set(ClipboardPolicy.ignoredByDefault) }
    public var onCapture: ((ClipCapture) -> Void)?
    /// Reads would raise macOS's alert or be refused: the history waits until the user allows dock2.
    public private(set) var isPaused = false
    public var onPauseChange: ((Bool) -> Void)?

    public static let interval = 0.25

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastSeen = pasteboard.changeCount
    }

    /// Watches from now on. What is there already is touched, not kept — so any alert macOS raises answers
    /// the user's choice rather than a later copy — since who copied it is no longer known: an ignored app's
    /// copy must not be kept under whatever app is in front now.
    public func start() {
        guard timer == nil else { return }
        lastSeen = pasteboard.changeCount
        if mayRead, let item = pasteboard.pasteboardItems?.first, let type = item.types.first { _ = item.data(forType: type) }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// After dock2 writes to the pasteboard: that change is its own.
    public func wrote(changeCount: Int) {
        ownWrites.insert(changeCount)
    }

    /// `.ask` and `.alwaysDeny` would turn every copy into an alert or nothing: the history pauses.
    /// `.default` reads, once the user has turned the history on, so any alert answers that choice.
    private var mayRead: Bool {
        switch pasteboard.accessBehavior {
        case .ask, .alwaysDeny: false
        default: true
        }
    }

    func check() {
        // Paused or not as macOS's answer changes, copy or no copy.
        let paused = !mayRead
        if paused != isPaused {
            isPaused = paused
            onPauseChange?(paused)
        }
        let count = pasteboard.changeCount
        guard count != lastSeen else { return }
        lastSeen = count
        if ownWrites.remove(count) != nil { return }
        capture()
    }

    private func capture() {
        guard !isPaused, let pending = read() else { return }
        // An image is made compact off the main thread — a large one takes a while — and comes back to it.
        guard pending.isImage else {
            if let capture = pending.build() { onCapture?(capture) }
            return
        }
        Self.imaging.async { [weak self] in
            let capture = pending.build()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let capture { self?.onCapture?(capture) }
                }
            }
        }
    }

    private static let imaging = DispatchQueue(label: "zip.tanner.dock2.clipboard-images", qos: .utility)

    /// What a copy's capture is made from, read on the main thread; `build` may run anywhere.
    private struct Pending: Sendable {
        let isImage: Bool
        let build: @Sendable () -> ClipCapture?
    }

    private func read() -> Pending? {
        guard let items = pasteboard.pasteboardItems, let first = items.first else { return nil }
        let types = first.types.map(\.rawValue)
        // The app that copied it, by nspasteboard.org's source marker where the copy has one, else the app in
        // front: what dock2 copies for the user — Files' ⌘C, Copy Path — is kept as dock2's.
        let source = first.string(forType: OwnWrite.sourceType)
        let front = NSWorkspace.shared.frontmostApplication
        let copier = source ?? front?.bundleIdentifier
        let copierName = source.map { id in
            id == Dock2Identity.bundleIdentifier ? "dock2" : NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
        } ?? front?.localizedName
        // The size is known only once read: decide on the types first, then on the bytes.
        guard case .keep(let kind) = ClipboardPolicy.decide(types: types, frontApp: copier, ignored: ignoredApps(), size: 0) else { return nil }
        var raw: [String: Data] = [:]
        var files: [String] = []
        if kind == .files {
            files = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.path }
            guard !files.isEmpty else { return nil }
            raw["public.file-url"] = Data(files.joined(separator: "\n").utf8)
        } else {
            for type in ClipboardPolicy.types(for: kind, among: types) {
                if let bytes = first.data(forType: NSPasteboard.PasteboardType(type)) { raw[type] = bytes }
            }
        }
        let title: String = switch kind {
        case .files: files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"
        case .image: "Image"
        case .color: "Colour"
        case .link: first.string(forType: .URL) ?? first.string(forType: .string) ?? "Link"
        case .richText, .text: ClipEntry.title(from: first.string(forType: .string) ?? "")
        }
        guard !title.isEmpty else { return nil }
        let text = [.text, .richText, .link].contains(kind) ? first.string(forType: .string).map(ClipEntry.searchText(from:)) : nil
        let (app, appName, captured) = (copier, copierName, Date())
        return Pending(isImage: kind == .image) { [raw, files] in
            guard let data = kind == .image ? Self.compactImage(raw) : raw else { return nil }
            let size = data.values.map(\.count).reduce(0, +)
            guard size > 0, size <= ClipboardPolicy.sizeCap else { return nil }
            let primary = data.keys.sorted().first.flatMap { data[$0] } ?? Data()
            let digest = SHA256.hash(data: primary + Data(kind.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
            let entry = ClipEntry(kind: kind, title: title, files: files, digest: digest, date: captured, sourceApp: app,
                                  sourceName: appName, types: Array(data.keys), size: size,
                                  thumbnail: kind == .image ? Self.thumbnail(data) : nil, searchText: text)
            return ClipCapture(entry: entry, data: data)
        }
    }

    /// An image as the history keeps it, and the cap measures it: its compressed forms if the copy has any,
    /// else its TIFF — which macOS hands over uncompressed, 13 MB for a 600 × 400 picture — as a PNG, unless
    /// it is past 40 megapixels, whose PNG would be past the cap anyway.
    nonisolated static func compactImage(_ raw: [String: Data]) -> [String: Data]? {
        let compressed = raw.filter { ["public.png", "public.jpeg", "public.heic"].contains($0.key) }
        if !compressed.isEmpty { return compressed }
        guard let tiff = raw["public.tiff"], let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width * height <= 40_000_000, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? ["public.png": png as Data] : nil
    }

    /// The image at a row icon's size, twice over for Retina: ImageIO's thumbnail, which reads no more of a
    /// large picture than it must.
    nonisolated static func thumbnail(_ data: [String: Data]) -> Data? {
        guard let bytes = ["public.png", "public.tiff", "public.jpeg", "public.heic"].lazy.compactMap({ data[$0] }).first,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 72,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// dock2's own writes ([clipboard](product/clipboard.md#what-is-kept)), marked with nspasteboard.org's source
/// type naming dock2, so any app — the history too — can tell where a copy came from.
@MainActor
public enum OwnWrite {
    public static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// Clears `pasteboard`, lets `write` fill it, and marks it dock2's; returns the change count it made.
    @discardableResult
    public static func write(to pasteboard: NSPasteboard = .general, _ write: (NSPasteboard) -> Void) -> Int {
        pasteboard.clearContents()
        write(pasteboard)
        pasteboard.addTypes([sourceType], owner: nil)
        pasteboard.setString(Dock2Identity.bundleIdentifier, forType: sourceType)
        return pasteboard.changeCount
    }
}

/// Putting an entry back, and pasting it ([clipboard](product/clipboard.md#actions)).
@MainActor
public enum Paster {
    /// Writes the entry's data — only its plain text when `plain` — and returns the change count it made.
    @discardableResult
    public static func write(_ entry: ClipEntry, data: [String: Data], plain: Bool = false, to pasteboard: NSPasteboard = .general) -> Int {
        OwnWrite.write(to: pasteboard) { pasteboard in
            if entry.kind == .files, let list = data["public.file-url"].map({ String(decoding: $0, as: UTF8.self) }) {
                let urls = list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
                pasteboard.writeObjects(urls)
            } else if plain {
                let text = data["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } ?? entry.title
                pasteboard.setString(text, forType: .string)
            } else {
                let item = NSPasteboardItem()
                for (type, bytes) in data { item.setData(bytes, forType: NSPasteboard.PasteboardType(type)) }
                pasteboard.writeObjects([item])
            }
        }
    }

    /// Posting ⌘V needs Accessibility.
    public static var canPaste: Bool { CGPreflightPostEventAccess() }

    /// The system's request for Accessibility, once.
    public static func requestAccess() {
        _ = CGRequestPostEventAccess()
    }

    /// ⌘V to the app in front, as if typed.
    public static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
