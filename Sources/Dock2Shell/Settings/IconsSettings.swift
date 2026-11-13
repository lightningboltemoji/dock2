import AppKit
import Dock2Core
import Dock2System
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Icons ([icons](product/icons.md#the-section)): the Files tile, then the apps on the dock in its
/// order, then any other `[icons]` gives an icon, each a row with its own icon and a well with the one it wears.
struct IconsSection: View {
    let model: SettingsModel
    let apps: AppDirectory
    /// The apps with tiles, in the dock's order: pinned, running, sidelined.
    let dockApps: () -> [AppRef]
    @Bindable var navigation: SettingsNavigation
    let scroll: ScrollViewProxy
    /// Apps added with Other App… that the file gives no icon yet.
    @State private var others: [AppRef] = []
    /// The pack the open row is choosing among.
    @State private var pack: IconPack?
    /// Why a file the open row was given was refused.
    @State private var problem: String?

    var body: some View {
        let icons = model.store.icons
        Section {
            ForEach(keys(icons), id: \.self) { key in row(key, icons: icons) }
        } footer: {
            Text("A tile wears its icon on the dock and wherever Dock2 shows the app — search, Open With. Finder, ⌘⇥ and Launchpad show the app's own.")
        }
        Section {
            Button("Other App…", action: addApp)
        } footer: {
            Text("An Icon Composer icon is chosen compiled, as the asset catalog (.car) actool builds. Dock2 copies it into icons/ beside config.toml.")
        }
        .onChange(of: navigation.icon, initial: true) { _, key in opened(key, icons: model.store.icons) }
    }

    /// The Files tile, the dock's apps, then the rest the file names, then those added here.
    private func keys(_ icons: TileIcons) -> [TileIconKey] {
        var apps: [AppRef] = []
        for app in dockApps() + icons.entries.compactMap(\.app) + others where !apps.contains(app) { apps.append(app) }
        return [.files] + apps.map(TileIconKey.app)
    }

    private func row(_ key: TileIconKey, icons: TileIcons) -> some View {
        let own = ownIcon(key)
        let worn = icons[key].flatMap { apps.draw($0, for: key) } ?? own
        return LabeledContent {
            Button { navigation.icon = key } label: {
                Image(nsImage: worn).resizable().frame(width: 32, height: 32)
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Change \(name(key))'s icon")
            .accessibilityLabel("\(name(key))'s icon")
            .popover(isPresented: Binding(get: { navigation.icon == key }, set: { if !$0, navigation.icon == key { navigation.icon = nil } }),
                     arrowEdge: .trailing) {
                IconPicker(own: own, ownTitle: key == .files ? "Finder" : name(key), current: icons[key], color: $navigation.iconColor, filled: $navigation.iconFilled,
                           pack: pack, problem: problem, choose: { model.store.setIcon($0, for: key) },
                           chooseFile: { chooseFile(for: key) }, pick: { name in pick(name, for: key) }, leavePack: { pack = nil })
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.pathExtension.lowercased() == "car" else { return false }
                Task { await choose(url, for: key) }
                return true
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: own).resizable().frame(width: 20, height: 20)
                Text(name(key))
            }
        }
        .id(key)
    }

    private func name(_ key: TileIconKey) -> String {
        switch key {
        case .files: "Files"
        case .app(let app): apps.entry(app)?.name ?? key.key
        }
    }

    /// The tile's own icon: Finder's, for Files.
    private func ownIcon(_ key: TileIconKey) -> NSImage {
        let app = switch key {
        case .files: AppRef.finder
        case .app(let app): app
        }
        return apps.entry(app)?.own ?? NSWorkspace.shared.icon(for: .application)
    }

    /// A row's choices opened, from its well or a tile's Change Icon…: fresh, its picture's colour and fill
    /// taken up, and the row brought into view.
    private func opened(_ key: TileIconKey?, icons: TileIcons) {
        guard let key else { return }
        if case .app(let app) = key, !keys(icons).contains(key) { others.append(app) }
        if case .picture(let icon) = icons[key] {
            navigation.iconColor = icon.color
            navigation.iconFilled = icon.filled
        }
        withAnimation { scroll.scrollTo(key, anchor: .center) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let app = AppRef(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, path: url.path)
        if !others.contains(app) { others.append(app) }
        navigation.icon = .app(app)
    }

    private func chooseFile(for key: TileIconKey) {
        let panel = NSOpenPanel()
        // A catalog has no type of its own: it is taken by its extension.
        panel.allowedContentTypes = [UTType(filenameExtension: "car")].compactMap { $0 }
        panel.message = "Choose an Icon Composer icon, compiled: an asset catalog (.car)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await choose(url, for: key) }
    }

    /// A file chosen or dropped: one icon is worn at once, a pack opens its grid, and anything else is refused,
    /// saying why.
    private func choose(_ url: URL, for key: TileIconKey) async {
        pack = nil
        problem = nil
        do throws(IconFileProblem) {
            let (hash, contents) = try await apps.files.contents(of: url)
            if contents.icons.count > 1 {
                pack = IconPack(url: url, hash: hash, icons: contents.icons.map { icon in
                    IconPack.Icon(name: icon, image: apps.files.shim(url, hash: hash, icon: icon).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                })
                navigation.icon = key
            } else {
                _ = try contents.icon(named: nil)
                place(url, hash: hash, icon: nil, for: key)
            }
        } catch {
            problem = "\(url.lastPathComponent) \(error.reason)."
            navigation.icon = key
        }
    }

    private func pick(_ icon: String, for key: TileIconKey) {
        guard let pack else { return }
        place(pack.url, hash: pack.hash, icon: icon, for: key)
    }

    /// Copied beside the settings, so it travels with them and an emptied Downloads folder takes nothing.
    private func place(_ url: URL, hash: String, icon: String?, for key: TileIconKey) {
        do {
            let path = try TileIconFiles.place(url, hash: hash, in: model.store.file.folder)
            model.store.setIcon(.file(path: path, name: icon), for: key)
            pack = nil
        } catch {
            problem = "\(url.lastPathComponent) could not be copied beside config.toml: \(error.localizedDescription)"
            navigation.icon = key
        }
    }
}

/// A pack's icons, each drawn through its shim as a tile would wear it.
struct IconPack {
    struct Icon: Identifiable {
        let name: String
        let image: NSImage
        var id: String { name }
    }

    let url: URL
    let hash: String
    let icons: [Icon]
}

/// A row's choices: its own icon first, then Cairo's pictures with the colour and the fill, and Choose File…
/// for an Icon Composer icon — or, once a pack is chosen, its icons.
private struct IconPicker: View {
    let own: NSImage
    let ownTitle: String
    let current: TileIcon?
    @Binding var color: IconColor
    @Binding var filled: Bool
    let pack: IconPack?
    let problem: String?
    let choose: (TileIcon?) -> Void
    let chooseFile: () -> Void
    let pick: (String) -> Void
    let leavePack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pack {
                HStack {
                    Button(action: leavePack) { Label("Back", systemImage: "chevron.left") }
                    Text(pack.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                }
                grid {
                    ForEach(pack.icons) { icon in
                        cell(icon.image, title: icon.name, selected: { if case .file(_, icon.name?) = current { true } else { false } }()) {
                            pick(icon.name)
                        }
                    }
                }
            } else {
                grid {
                    cell(own, title: ownTitle, selected: current == nil) { choose(nil) }
                    ForEach(CairoPicture.allCases, id: \.self) { picture in
                        let icon = PictureIcon(picture: picture, color: color, filled: filled)
                        cell(PictureIconImage.image(icon) ?? own, title: picture.title, selected: chosen == picture) { choose(.picture(icon)) }
                    }
                }
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .disabled(chosen == nil)
                Toggle("Fill", isOn: Binding(get: { filled }, set: { filled = $0; rechoose() }))
                    .disabled(chosen == nil)
                Divider()
                HStack {
                    Button("Choose File…", action: chooseFile)
                    if case .file(let path, let name) = current {
                        Text(name.map { "\(path), \($0)" } ?? path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 380)
    }

    /// The picture worn, if one is.
    private var chosen: CairoPicture? {
        if case .picture(let icon) = current { icon.picture } else { nil }
    }

    /// The picture worn again in the colour and fill as they now are.
    private func rechoose() {
        guard let chosen else { return }
        choose(.picture(PictureIcon(picture: chosen, color: color, filled: filled)))
    }

    private func grid(@ViewBuilder _ cells: () -> some View) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 2)], spacing: 2, content: cells)
        }
        .frame(maxHeight: 300)
    }

    private func cell(_ image: NSImage, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(nsImage: image).resizable().frame(width: 40, height: 40)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The colour as Display P3's components, which is how `[icons]` keeps it.
    private var colorBinding: Binding<Color> {
        Binding(get: {
            Color(.displayP3, red: color.red, green: color.green, blue: color.blue)
        }, set: { new in
            guard let p3 = NSColor(new).usingColorSpace(.displayP3) else { return }
            color = IconColor(red: p3.redComponent, green: p3.greenComponent, blue: p3.blueComponent)
            rechoose()
        })
    }
}

private extension TileIcons.Entry {
    var app: AppRef? {
        if case .app(let app) = key { app } else { nil }
    }
}
