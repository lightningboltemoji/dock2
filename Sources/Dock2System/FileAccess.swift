import AppKit
import Dock2Core

/// What macOS lets dock2 see of the user's files ([access](product/files/access.md)).
public enum FileAccess {
    public static let protectedFolders = ["Desktop", "Documents", "Downloads"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0, isDirectory: true)
    }

    /// Read only with Full Disk Access, and refused silently without it: no prompt.
    static let fullDiskAccessProbe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")

    /// For development, `DOCK2_FULL_DISK_ACCESS=off` acts as if dock2 had none: a terminal that runs it
    /// usually has it, which hides every locked place.
    /// Looked at once a second at most: a listing asks it of every folder in it.
    public static var hasFullDiskAccess: Bool {
        if LaunchEnvironment.variables["DOCK2_FULL_DISK_ACCESS"] == "off" { return false }
        let now = Date()
        if let (answer, at) = lastProbe.value, now.timeIntervalSince(at) < 1 { return answer }
        let answer = (try? FileManager.default.contentsOfDirectory(atPath: fullDiskAccessProbe.path)) != nil
        lastProbe.value = (answer, now)
        return answer
    }

    private static let lastProbe = Box<(Bool, Date)?>(nil)

    /// An answer to the ask ([access](product/files/access.md#the-ask)), wherever it was asked: recorded, then
    /// done — System Settings opened, or macOS's prompt for each folder raised.
    @MainActor
    public static func answer(_ choice: FileAccessChoice, settings: SettingsStore, folders done: @escaping @Sendable ([URL]) -> Void = { _ in },
                              granted: (@MainActor () -> Void)? = nil) {
        settings[Settings.fileAccess] = choice
        switch choice {
        case .fullDisk:
            NSWorkspace.shared.open(fullDiskAccessPane)
            if let granted { awaitFullDiskAccess(granted) }
        case .folders: requestFolders(done)
        case .declined, .notAsked: break
        }
    }

    @MainActor private static var waiting: Timer?

    /// Looks every two seconds, for ten minutes, for the grant to land — the probe becoming readable — and
    /// tells `granted` once. One wait at a time: a second replaces the first.
    @MainActor
    public static func awaitFullDiskAccess(_ granted: @escaping @MainActor () -> Void) {
        waiting?.invalidate()
        let giveUp = Date().addingTimeInterval(600)
        waiting = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard hasFullDiskAccess || Date() > giveUp else { return }
                waiting?.invalidate()
                waiting = nil
                if hasFullDiskAccess { granted() }
            }
        }
    }

    /// Whether looking in `folder` — listing it, or naming it in a query's scope — would prompt or be refused
    /// without Full Disk Access, by its spelling alone: a check cheap enough for every item in a listing.
    /// Choosing Full Disk Access is not the grant.
    public static func isClosed(_ folder: URL, choice: FileAccessChoice) -> Bool {
        !hasFullDiskAccess && asks(folder, choice: choice)
    }

    /// As `isClosed`, for the one folder about to be opened — listed, watched, completed — whose path may run
    /// through a symbolic link: judged where its links lead, each read on its own.
    public static func isClosedReached(_ folder: URL, choice: FileAccessChoice) -> Bool {
        guard !hasFullDiskAccess else { return false }
        return asks(folder, choice: choice) || asks(URL(fileURLWithPath: reached(folder.path, choice: choice), isDirectory: true), choice: choice)
    }

    /// Whether looking in `folder` would ask or be refused, were dock2 without Full Disk Access, by its spelling
    /// — case ignored, the Data volume's firmlinks undone. Asked about each, a protected folder is closed only if
    /// macOS refused it; other apps' data always is.
    public static func asks(_ folder: URL, choice: FileAccessChoice) -> Bool {
        let path = spelled(folder.path)
        if otherAppsPaths.contains(where: { within($0, path, inside: true) }) { return true }
        guard let root = protectedRoot(of: path) else { return false }
        return choice != .folders || refused.contains(root)
    }

    /// The protected folder `path` is or is in, by its spelling.
    public static func protectedRoot(of path: String) -> URL? {
        let path = spelled(path)
        return zip(protectedFolders, protectedPaths).first { within($0.1, path, inside: false) }?.0
    }

    private static let protectedPaths = protectedFolders.map { $0.path.lowercased() }
    private static let otherAppsPaths = otherAppsData.map { $0.path.lowercased() }

    /// `path`, lowercased, with the Data volume's firmlinks undone: what the Mac's case-blind volume compares.
    private static func spelled(_ path: String) -> String {
        let path = path.lowercased()
        return path.hasPrefix("/system/volumes/data/") ? String(path.dropFirst("/system/volumes/data".count)) : path
    }

    private static func within(_ root: String, _ path: String, inside: Bool) -> Bool {
        (!inside && path == root) || path.hasPrefix(root + "/")
    }

    /// `path` as the file system reaches it: each symbolic link along it followed by reading the link alone,
    /// never inside a folder closed to dock2, a link there included; at most 32 links.
    public static func reached(_ path: String, choice: FileAccessChoice) -> String {
        var pending = path.split(separator: "/").map(String.init)
        var reached: [String] = []
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = reached.popLast(); continue }
            let next = "/" + (reached + [part]).joined(separator: "/")
            // Read only in a folder open to dock2: the one holding `next`.
            let holder = URL(fileURLWithPath: "/" + reached.joined(separator: "/"), isDirectory: true)
            if !asks(holder, choice: choice), links < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) {
                links += 1
                if target.hasPrefix("/") { reached = [] }
                pending = target.split(separator: "/").map(String.init) + pending
                continue
            }
            reached.append(part)
        }
        return "/" + reached.joined(separator: "/")
    }

    /// The protected folders macOS keeps closed, for a user who chose to be asked about each. Learned off the
    /// main thread — opening one macOS has not answered for asks, and waits on the answer — at most once a
    /// second; until known, or while macOS is asking, all three are closed. `foldersChanged` says when it moves.
    public static var refused: Set<URL> {
        if answering.value { return Set(protectedFolders) }
        // A learner still out after a quarter second is waiting on macOS's ask: closed until it is answered.
        if let since = learningSince.value, Date().timeIntervalSince(since) > 0.25 { return Set(protectedFolders) }
        let known = lastRefused.value
        if known.map({ Date().timeIntervalSince($0.at) >= 1 }) ?? true { learnRefused() }
        return known?.folders ?? Set(protectedFolders)
    }

    /// Posted on the main queue when what macOS keeps closed changes: listings and Settings read it again.
    public static let foldersChanged = Notification.Name("zip.tanner.dock2.folders-changed")

    private static func learnRefused() {
        let starts = learningSince.update { since -> Bool in
            guard since == nil else { return false }
            since = Date()
            return true
        }
        guard starts else { return }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = Set(protectedFolders.filter { !canOpen($0) })
            // Slow, it had all three closed meanwhile: whoever looked then looks again.
            let changed = lastRefused.value?.folders != folders || Date().timeIntervalSince(started) > 0.25
            lastRefused.value = (folders, Date())
            learningSince.value = nil
            if changed { DispatchQueue.main.async { NotificationCenter.default.post(name: foldersChanged, object: nil) } }
        }
    }

    private static let lastRefused = Box<(folders: Set<URL>, at: Date)?>(nil)
    private static let answering = Box(false)
    private static let learningSince = Box<Date?>(nil)

    /// Places macOS asks about one at a time, besides the three folders: other apps' data. Without Full
    /// Disk Access Files shows them locked rather than raise a prompt by looking.
    public static let otherAppsData = ["Library/Containers", "Library/Group Containers"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0, isDirectory: true)
    }

    /// Spotlight's settings, where its Search Privacy list takes folders out of the index for every app.
    public static let spotlightPane = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!

    /// Privacy & Security → Files and Folders.
    public static let filesAndFoldersPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// Whether macOS lets dock2 into `folder` now: opened, not listed. Off the main thread: for a folder macOS
    /// has not answered about it raises the prompt, and waits.
    public static func canOpen(_ folder: URL) -> Bool {
        guard let directory = opendir(folder.path) else { return false }
        closedir(directory)
        return true
    }

    /// Privacy & Security → Paste from Other Apps.
    public static let pasteboardPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!

    /// Privacy & Security → Full Disk Access.
    public static let fullDiskAccessPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Lists each protected folder on a background queue, which raises macOS's prompt for each one not yet
    /// answered; `done` hears, on the main queue, which ones dock2 can now read.
    public static func requestFolders(_ done: @escaping @Sendable ([URL]) -> Void) {
        answering.value = true
        DispatchQueue.global(qos: .userInitiated).async {
            let readable = protectedFolders.filter { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
            answering.value = false
            lastRefused.value = nil
            learnRefused()
            DispatchQueue.main.async { done(readable) }
        }
    }
}
