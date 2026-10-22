import Dock2Core
import Dock2Plugins
import Dock2System
import SwiftUI

/// What the Settings window can ask the app to do.
@MainActor
struct SettingsActions {
    var quit: () -> Void
    var runFirstLaunch: () -> Void
    var collectLogs: () -> Void
    var clearClipboard: () -> Void
    /// macOS would ask, or refuse, before dock2 reads the clipboard.
    /// The history's store could not be opened: kept in memory only.
    var clipboardUnsaved: () -> Bool
    var plugins: PluginsModel?
    var picks: PicksStore
    var shortcuts: ShortcutStatus
}

/// The global shortcuts macOS would not register — another app, or the system, holds the chord — by their
/// settings' names.
@MainActor
@Observable
final class ShortcutStatus {
    private(set) var refused: Set<String> = []

    func set(_ name: String, registered: Bool) {
        if registered { refused.remove(name) } else { refused.insert(name) }
    }
}

/// dock2's Settings: a sidebar of sections ([settings](product/settings.md)), each row a setting that applies
/// the moment it changes.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General", dock = "Dock", search = "Search", clipboard = "Clipboard", files = "Files", shortcuts = "Shortcuts"
        case plugins = "Plugins"
        case permissions = "Permissions"
        case about = "About"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .dock: "dock.rectangle"
            case .search: "magnifyingglass"
            case .clipboard: "list.clipboard"
            case .files: "folder"
            case .shortcuts: "command"
            case .plugins: "puzzlepiece.extension"
            case .permissions: "lock.shield"
            case .about: "info.circle"
            }
        }
    }

    let model: SettingsModel
    let actions: SettingsActions
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $navigation.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Form {
                switch navigation.section ?? .general {
                case .general: GeneralSection(model: model, shortcuts: actions.shortcuts)
                case .dock: DockSection(model: model)
                case .search: SearchSettingsSection(model: model, picks: actions.picks, plugins: actions.plugins)
                case .clipboard: ClipboardSection(model: model, actions: actions)
                case .files: FilesSection(model: model)
                case .shortcuts: ShortcutsSection(model: model, shortcuts: actions.shortcuts)
                case .plugins:
                    if let plugins = actions.plugins { PluginsSection(model: plugins) }
                case .permissions: PermissionsSection(model: model)
                case .about: AboutSection(actions: actions)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigation.section?.rawValue ?? "")
        }
        .onAppear { model.refresh() }
    }
}

private struct GeneralSection: View {
    let model: SettingsModel
    let shortcuts: ShortcutStatus
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: { value in
                loginError = LoginItem.set(value)
                loginEnabled = LoginItem.isEnabled
            }))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
        }
        Section {
            SummonShortcut(model: model, shortcuts: shortcuts)
        } footer: {
            Text("⌘Space switches Spotlight's own shortcut off while Dock2 runs; it comes back when Dock2 quits.")
        }
    }
}

/// The summon shortcut: Spotlight's ⌘space taken over, a chord of the user's, or none.
private struct SummonShortcut: View {
    let model: SettingsModel
    let shortcuts: ShortcutStatus

    var body: some View {
        let summon = model.binding(Settings.summon)
        Picker("Open Dock2 with", selection: Binding(get: { Choice(summon.wrappedValue) }, set: { choice in
            switch choice {
            case .commandSpace: summon.wrappedValue = .commandSpace
            case .none: summon.wrappedValue = .none
            case .chord: if case .chord = summon.wrappedValue {} else { summon.wrappedValue = .chord(Self.defaultChord) }
            }
        })) {
            Text("⌘Space, in place of Spotlight").tag(Choice.commandSpace)
            Text("Another shortcut").tag(Choice.chord)
            Text("None").tag(Choice.none)
        }
        if case .chord = summon.wrappedValue {
            GlobalShortcutRow(title: "Shortcut", shortcut: summon, refused: shortcuts.refused.contains(Settings.summon.name))
        }
    }

    private enum Choice: Hashable {
        case commandSpace, chord, none
        init(_ shortcut: Shortcut) {
            switch shortcut {
            case .commandSpace: self = .commandSpace
            case .chord: self = .chord
            case .none: self = .none
            }
        }
    }

    /// ⌥⌘Space, until the user records their own.
    private static let defaultChord = KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.command | KeyChord.option)
}

/// A global shortcut's recorder, and beneath it what the chord takes from dock2 itself, if anything
/// ([keyboard](product/keyboard.md#files)).
private struct GlobalShortcutRow: View {
    let title: String
    let shortcut: Binding<Shortcut>
    /// macOS would not register it.
    var refused = false

    var body: some View {
        LabeledContent(title) {
            ShortcutRecorder(chord: Binding(get: { if case .chord(let chord) = shortcut.wrappedValue { chord } else { nil } },
                                            set: { shortcut.wrappedValue = $0.map { .chord($0) } ?? .none }))
        }
        if refused {
            Text("macOS would not let Dock2 have it: the system or another app already uses it. Choose another.")
                .font(.caption).foregroundStyle(.red)
        } else if case .chord(let chord) = shortcut.wrappedValue, let taken = ReservedKeys.taken(by: chord) {
            Text("It takes the place of \(taken).").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Search's sources, the folders it leaves out, and what it has learned ([search](product/search/README.md)).
private struct SearchSettingsSection: View {
    let model: SettingsModel
    let picks: PicksStore
    let plugins: PluginsModel?

    var body: some View {
        Section {
            Picker("The field, with nothing typed", selection: model.binding(Settings.fieldForm)) {
                ForEach(FieldForm.allCases, id: \.self) { form in Text(form.title).tag(form) }
            }
        } footer: {
            Text("What the search field is until you type, and how it becomes the field. Reduce Motion, Reduce Transparency and Increase Contrast show the capsule.")
        }
        Section {
            let off = model.binding(Settings.searchSourcesOff)
            ForEach(SectionID.builtIn, id: \.self) { section in
                Toggle(section.title, isOn: Binding(get: { !off.wrappedValue.contains(section.title) }, set: { on in
                    off.wrappedValue.removeAll { $0 == section.title }
                    if !on { off.wrappedValue.append(section.title) }
                }))
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("A plugin's results are switched on in Plugins.")
        }
        if let plugins {
            let answering = plugins.plugins.filter { $0.manifest.results != nil }.ordered(by: model[Settings.pluginOrder])
            if answering.count > 1 {
                Section("Plugins' results, in this order") {
                    ForEach(Array(answering.enumerated()), id: \.element.id) { index, plugin in
                        HStack {
                            Text(plugin.manifest.results?.title ?? plugin.manifest.name)
                            Spacer()
                            Button("Up") { move(answering, from: index, by: -1) }.disabled(index == 0)
                            Button("Down") { move(answering, from: index, by: 1) }.disabled(index == answering.count - 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        Section {
            FolderList(folders: model.binding(Settings.searchFirst))
        } header: {
            Text("Ranked first")
        } footer: {
            Text("Their files come first, with those in your home folders.")
        }
        Section {
            FolderList(folders: model.binding(Settings.searchExcluded))
            Button("Spotlight's Search Privacy…") { NSWorkspace.shared.open(FileAccess.spotlightPane) }
        } header: {
            Text("Excluded folders")
        } footer: {
            Text("Their files stay out of Dock2's results. Spotlight's own Search Privacy list takes them out for every app.")
        }
        Section {
            let learned = picks.picks.picks.sorted { $0.date > $1.date }
            if learned.isEmpty { Text("Nothing learned yet.").foregroundStyle(.secondary) }
            ForEach(learned, id: \.query) { pick in
                HStack {
                    Text("“\(pick.query)”")
                    Text(pick.title ?? Self.name(pick.id)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget") { picks.update { $0.forget(pick.query) } }.buttonStyle(.borderless)
                }
            }
            if !learned.isEmpty { Button("Forget All") { picks.update { $0.clear() } } }
        } header: {
            Text("Learned picks")
        } footer: {
            Text("What you choose for a query comes first the next time you type it. Picks stay on this Mac.")
        }
    }

    /// A pick recorded without its title: a file by its name, anything else by its id.
    private static func name(_ id: String) -> String {
        id.hasPrefix("file:") ? (id.dropFirst(5) as NSString).lastPathComponent : id
    }

    private func move(_ answering: [InstalledPlugin], from index: Int, by step: Int) {
        var ids = answering.map(\.id)
        ids.swapAt(index, index + step)
        model.store[Settings.pluginOrder] = ids
    }
}

/// Every global shortcut, in one list ([settings](product/settings.md#sections)).
private struct ShortcutsSection: View {
    let model: SettingsModel
    let shortcuts: ShortcutStatus

    var body: some View {
        Section {
            SummonShortcut(model: model, shortcuts: shortcuts)
            GlobalShortcutRow(title: "Open Clipboard History with", shortcut: model.binding(Settings.clipboardShortcut),
                              refused: shortcuts.refused.contains(Settings.clipboardShortcut.name))
        } footer: {
            Text("A shortcut here works in every app. One set on a key Dock2 uses itself takes that key from Dock2 too.")
        }
    }
}

private struct DockSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            let size = model.binding(Settings.tileSize)
            LabeledContent("Size") {
                Slider(value: size, in: DockMetrics.tileSizes) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Small")
                } maximumValueLabel: {
                    Text("Large")
                }
            }
        }
        Section {
            Toggle("Automatically hide and show the dock", isOn: model.binding(Settings.autohide))
            if model[Settings.autohide] {
                delay("Show after", model.binding(Settings.revealDelay))
                delay("Hide after", model.binding(Settings.hideDelay))
            }
        }
        Section {
            Toggle("Type to search when the dock appears", isOn: model.binding(Settings.typeToSearch))
            Toggle("Show numbers on the first nine apps while ⌘ is held", isOn: model.binding(Settings.numberBadges))
            Toggle("Bounce apps as they open", isOn: model.binding(Settings.bounce))
            Toggle("Show running apps that are not kept in the dock", isOn: model.binding(Settings.showRunning))
        }
    }

    private func delay(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...1)
                Text(String(format: "%.2f s", value.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct ClipboardSection: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmingClear = false
    /// macOS's answer for dock2, read again whenever dock2 comes forward: the history pauses on ask or deny.
    @State private var access = NSPasteboard.general.accessBehavior

    var body: some View {
        Section {
            Toggle("Keep a history of what you copy", isOn: model.binding(Settings.clipboardHistory))
            if model[Settings.clipboardHistory], access == .ask || access == .alwaysDeny {
                Text(access == .ask
                     ? "Paused: macOS asks before each read of the clipboard. In Paste from Other Apps, allow Dock2."
                     : "Paused: macOS does not let Dock2 read the clipboard. In Paste from Other Apps, allow Dock2.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open System Settings…") { NSWorkspace.shared.open(FileAccess.pasteboardPane) }
            }
            if model[Settings.clipboardHistory], actions.clipboardUnsaved() {
                Text("Not being saved: the Keychain has not given Dock2 the key the history is sealed with. What you copy is kept until Dock2 quits, and saved once the key comes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Keep for", selection: model.binding(Settings.clipboardRetentionDays)) {
                Text("A day").tag(1)
                Text("A week").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("A year").tag(365)
            }
            Picker("↩ on an entry", selection: model.binding(Settings.clipboardPastes)) {
                Text("Pastes it").tag(true)
                Text("Copies it").tag(false)
            }
        } footer: {
            Text("Kept on this Mac only, encrypted, never synced. Pinned entries stay until unpinned.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access = NSPasteboard.general.accessBehavior
        }
        Section {
            GlobalShortcutRow(title: "Open Clipboard History with", shortcut: model.binding(Settings.clipboardShortcut),
                              refused: actions.shortcuts.refused.contains(Settings.clipboardShortcut.name))
        }
        Section("Never kept from") {
            let ignored = model.binding(Settings.clipboardIgnored)
            ForEach(ignored.wrappedValue, id: \.self) { id in
                HStack {
                    Text(Self.name(of: id))
                    Spacer()
                    Button("Remove") { ignored.wrappedValue.removeAll { $0 == id } }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add an App…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
                      !ignored.wrappedValue.contains(id) else { return }
                ignored.wrappedValue.append(id)
            }
        }
        Section {
            Button("Clear History…", role: .destructive) { confirmingClear = true }
                .confirmationDialog("Clear the clipboard history?", isPresented: $confirmingClear) {
                    Button("Clear History", role: .destructive, action: actions.clearClipboard)
                } message: {
                    Text("Every entry goes, pinned ones too.")
                }
        }
    }

    /// The password managers ignored out of the box, by name, for when they are not installed.
    private static let known = ["com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                                "com.bitwarden.desktop": "Bitwarden", "com.apple.Passwords": "Passwords",
                                "com.apple.keychainaccess": "Keychain Access"]

    private static func name(of id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        } ?? known[id] ?? id
    }
}

private struct FilesSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            Toggle("Folders first", isOn: model.binding(Settings.foldersFirst))
            Toggle("Show hidden files", isOn: model.binding(Settings.showHiddenFiles))
            Toggle("Show the preview column", isOn: model.binding(Settings.previewColumn))
        }
        Section {
            Toggle("“Show in Finder” opens Files", isOn: model.binding(Settings.showInFinderTakeover))
        } footer: {
            Text("Any app's Show in Finder shows the items in Files instead. Finder keeps the desktop, the Trash and Get Info.")
        }
    }
}

/// Folders, each with Remove, and Add a Folder….
private struct FolderList: View {
    @Binding var folders: [String]

    var body: some View {
        ForEach(folders, id: \.self) { path in
            HStack {
                Text((path as NSString).abbreviatingWithTildeInPath)
                Spacer()
                Button("Remove") { folders.removeAll { $0 == path } }.buttonStyle(.borderless)
            }
        }
        Button("Add a Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            folders += panel.urls.map(\.path).filter { !folders.contains($0) }
        }
    }
}

/// What macOS lets dock2 do, each with what it is for and the way to its pane ([permissions](product/system/permissions.md)).
private struct PermissionsSection: View {
    let model: SettingsModel
    @State private var fullDisk = FileAccess.hasFullDiskAccess
    /// Each of the three folders, and whether macOS let dock2 in: looked at only once the user chose to be
    /// asked about them, since looking asks.
    @State private var folders: [(name: String, open: Bool)] = []
    @State private var accessibility = AXIsProcessTrusted()
    @State private var pasteboard = NSPasteboard.general.accessBehavior

    var body: some View {
        Section {
            status("Full Disk Access", granted: fullDisk, detail: "Files and search see everything, everywhere.")
            if !fullDisk {
                Button("Open System Settings…") {
                    NSWorkspace.shared.open(FileAccess.fullDiskAccessPane)
                    FileAccess.awaitFullDiskAccess { fullDisk = true }
                }
                if model[Settings.fileAccess] != .folders {
                    Button("Just Desktop, Documents and Downloads") {
                        FileAccess.answer(.folders, settings: model.store, folders: { _ in Task { @MainActor in readFolders() } })
                    }
                } else {
                    ForEach(folders, id: \.name) { folder in
                        status(folder.name, granted: folder.open, detail: folder.open ? "Shown and found." : "macOS keeps it closed to Dock2.")
                    }
                    if folders.contains(where: { !$0.open }) {
                        Button("Open Files and Folders…") { NSWorkspace.shared.open(FileAccess.filesAndFoldersPane) }
                    }
                }
            }
        } header: {
            Text("Files")
        } footer: {
            if !fullDisk {
                Text(model[Settings.fileAccess] == .folders
                     ? "Other apps' data stays out of sight without Full Disk Access."
                     : "Without it, Desktop, Documents and Downloads are locked in Files, and search leaves them out.")
            }
        }
        .onAppear { readFolders() }
        Section {
            status("Accessibility", granted: accessibility, detail: "Sends the paste from clipboard history; without it, ↩ copies instead.")
            if !accessibility {
                Button("Open System Settings…") { NSWorkspace.shared.open(FileAccess.accessibilityPane) }
            }
            status("Paste from Other Apps", granted: pasteboard == .alwaysAllow, detail: "Lets clipboard history read what you copy.",
                   state: pasteboardState)
            if pasteboard != .alwaysAllow {
                Button("Open System Settings…") { NSWorkspace.shared.open(FileAccess.pasteboardPane) }
            }
        } header: {
            Text("Clipboard")
        }
        .onReceive(NotificationCenter.default.publisher(for: FileAccess.foldersChanged)) { _ in readFolders() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDisk = FileAccess.hasFullDiskAccess
            readFolders()
            accessibility = AXIsProcessTrusted()
            pasteboard = NSPasteboard.general.accessBehavior
        }
    }

    private func readFolders() {
        guard !fullDisk, model[Settings.fileAccess] == .folders else { return folders = [] }
        let refused = FileAccess.refused
        folders = FileAccess.protectedFolders.map { ($0.lastPathComponent, !refused.contains($0)) }
    }

    /// macOS's answer for dock2: until the user gives one, the first read asks.
    private var pasteboardState: String {
        switch pasteboard {
        case .alwaysAllow: "Allowed"
        case .alwaysDeny: "Not allowed"
        case .ask: "Asks each time"
        default: "Not asked yet"
        }
    }

    private func status(_ title: String, granted: Bool, detail: String, state: String? = nil) -> some View {
        LabeledContent {
            Label(state ?? (granted ? "Allowed" : "Not allowed"), systemImage: granted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(granted ? .green : .secondary)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

private struct AboutSection: View {
    let actions: SettingsActions

    var body: some View {
        Section {
            LabeledContent("Version", value: Dock2Identity.version)
        }
        Section {
            Button("Show the first-launch sequence again…", action: actions.runFirstLaunch)
            Button("Collect logs for a bug report…", action: actions.collectLogs)
        }
        Section {
            Button("Quit Dock2", role: .destructive, action: actions.quit)
        } footer: {
            Text("The system Dock, and everything else Dock2 took over, comes back as it was.")
        }
    }
}
