import AppKit
import Dock2Core
import Dock2System

/// Clipboard history ([clipboard](product/clipboard.md)): the watcher's captures kept in the sealed store,
/// pruned as they age; putting an entry back, and pasting it into the app in front.
@MainActor
final class ClipboardController {
    private let settings: SettingsStore
    private let store: ClipboardStore
    private let watcher = PasteboardWatcher()
    private(set) var history = ClipHistory()
    private var observations: [SettingsObservation] = []
    /// The store read, or found empty. Until then nothing is written over it — a key the Keychain withholds
    /// at launch must not cost the history it seals — and new copies' data waits here.
    private var opened = false
    private var opening = false
    private var waiting: [String: [String: Data]] = [:]
    /// The store could not be opened when last tried: Settings says the history is not being saved.
    private(set) var isUnsaved = false
    /// The history changed: search and the view redraw.
    var onChange: (() -> Void)?
    /// "Copied — ⌘V to paste", when the paste cannot be sent.
    var notice: ((String) -> Void)?

    init(settings: SettingsStore, store: ClipboardStore = ClipboardStore()) {
        self.settings = settings
        self.store = store
        watcher.onCapture = { [weak self] capture in self?.keep(capture) }
        watcher.ignoredApps = { [weak settings] in Set(settings?[Settings.clipboardIgnored] ?? ClipboardPolicy.ignoredByDefault) }
        watcher.onPauseChange = { paused in
            note(paused ? "clipboard history paused: macOS asks before dock2 reads the clipboard, or refuses" : "clipboard history resumed")
        }
    }

    func start() {
        apply()
        observations.append(settings.observe(Settings.clipboardHistory) { [weak self] _ in self?.apply() })
        observations.append(settings.observe(Settings.clipboardRetentionDays) { [weak self] _ in self?.prune() })
    }

    private func apply() {
        guard settings[Settings.clipboardHistory] else {
            watcher.stop()
            return
        }
        open()
        watcher.start()
    }

    /// Reads the store, and puts what was kept meanwhile on top of it; tried again at each copy until it works.
    private func open() {
        guard !opened, !opening else { return }
        opening = true
        store.load { [weak self] result in
            guard let self else { return }
            self.opening = false
            // Cleared while it loaded: what it read is what the user threw away.
            guard !self.opened else { return }
            guard case .success(let saved) = result else {
                self.isUnsaved = true
                return
            }
            var merged = saved
            for entry in self.history.entries.reversed() { merged.insert(entry) }
            self.history = merged
            self.opened = true
            self.isUnsaved = false
            for (id, data) in self.waiting where self.entry(id) != nil { self.store.save(data, for: id) }
            self.waiting = [:]
            self.prune()
            self.saveHistory()
            self.onChange?()
        }
    }

    private func saveHistory() {
        guard opened else { return }
        store.save(history)
    }

    private func keep(_ capture: ClipCapture) {
        let (kept, isNew) = history.insert(capture.entry)
        if isNew {
            if opened { store.save(capture.data, for: kept.id) } else { waiting[kept.id] = capture.data }
        }
        prune()
        saveHistory()
        if !opened { open() }
        onChange?()
    }

    private func prune() {
        let days = settings[Settings.clipboardRetentionDays]
        let removed = history.prune(now: Date(), retention: TimeInterval(days) * 24 * 3600)
        if !removed.isEmpty {
            for entry in removed { waiting[entry.id] = nil }
            store.remove(removed.map(\.id))
            saveHistory()
        }
    }

    func entry(_ id: String) -> ClipEntry? {
        history.entries.first { $0.id == id }
    }

    func data(for id: String) -> [String: Data]? {
        waiting[id] ?? store.data(for: id)
    }

    /// Back on the clipboard, and to the top of the history: not a copy of the user's.
    @discardableResult
    func copy(_ id: String, plain: Bool = false) -> Bool {
        guard let entry = entry(id), let data = data(for: id) else { return false }
        watcher.wrote(changeCount: Paster.write(entry, data: data, plain: plain))
        history.touch(id, at: Date())
        saveHistory()
        onChange?()
        return true
    }

    /// ↩: on the clipboard, then ⌘V into the app in front once dock2 has let go of the keyboard. Without
    /// Accessibility it only copies, and says so; the first time, the system asks for it.
    func paste(_ id: String, plain: Bool = false) {
        guard copy(id, plain: plain) else { return }
        Self.paste(settings: settings) { [weak self] in self?.notice?($0) }
    }

    /// ⌘V to the app in front, what is on the clipboard pasted — clipboard history's and plugins' — or,
    /// without Accessibility, a notice to paste by hand; the first time, macOS's ask, and dock2 says why.
    static func paste(settings: SettingsStore, notice: @escaping (String) -> Void) {
        guard Paster.canPaste else {
            if !settings[Settings.askedToPaste] {
                settings[Settings.askedToPaste] = true
                Paster.requestAccess()
                notice("Copied — ⌘V to paste. With Accessibility, dock2 pastes for you.")
                return
            }
            notice("Copied — ⌘V to paste")
            return
        }
        // The app in front takes its window's keys back a moment after dock2 deactivates.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { Paster.postPaste() }
    }

    static let pasteDelay = 0.15

    func setPinned(_ id: String, _ pinned: Bool) {
        history.setPinned(id, pinned)
        saveHistory()
        onChange?()
    }

    /// A copied file opened, or a copied link: what Open does in the history and in search.
    func open(_ id: String) {
        guard let entry = entry(id) else { return }
        if entry.kind == .files {
            entry.files.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
        } else if entry.kind == .link, let url = URL(string: entry.title) {
            NSWorkspace.shared.open(url)
        }
    }

    func delete(_ id: String) {
        history.remove(id)
        waiting[id] = nil
        store.remove([id])
        saveHistory()
        onChange?()
    }

    /// Settings' Clear History: everything, pinned or not — on disk too, opened or not, as the user asked.
    func clear() {
        history = ClipHistory()
        waiting = [:]
        store.clear()
        opened = true
        isUnsaved = false
        saveHistory()
        onChange?()
    }
}
