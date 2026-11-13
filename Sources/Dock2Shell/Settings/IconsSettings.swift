import AppKit
import Dock2Core
import Dock2System
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Icons ([icons](product/icons.md#the-section)): the Files tile, then the apps on the dock in its
/// order, then any other `[icons]` gives an icon, each a row with the icon it wears, what that is, and Change….
struct IconsSection: View {
    let model: SettingsModel
    let apps: AppDirectory
    /// The apps with tiles, in the dock's order: pinned, running, sidelined.
    let dockApps: () -> [AppRef]
    @Bindable var navigation: SettingsNavigation
    let scroll: ScrollViewProxy
    /// Apps added with Other App… that the file gives no icon yet.
    @State private var others: [AppRef] = []
    /// The pack a row is choosing among, and why a file a row was given was refused: each shown in that row alone.
    @State private var pack: (key: TileIconKey, icons: IconPack)?
    @State private var problem: (key: TileIconKey, text: String)?
    /// The row a `.car` is being dragged over.
    @State private var dropping: TileIconKey?

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
        let drawn = icons[key].flatMap { apps.draw($0, for: key) }
        return HStack(spacing: 10) {
            Image(nsImage: drawn ?? own).resizable().frame(width: IconCell.side, height: IconCell.side)
                .overlay { if dropping == key { IconCell.ring } }
                .onTapGesture { open(key) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name(key))
                wears(key, icons: icons, drawn: drawn != nil)
            }
            Spacer()
            Button("Change…") { open(key) }
                .help("Change \(name(key))'s icon")
                .accessibilityLabel("Change \(name(key))'s icon")
                .popover(isPresented: Binding(get: { navigation.icon == key }, set: { if !$0, navigation.icon == key { navigation.icon = nil } }),
                         arrowEdge: .trailing) {
                    IconPicker(own: own, ownTitle: name(key), finder: key == .files ? apps.entry(.finder)?.own : nil,
                               file: icons[key].flatMap { if case .file = $0 { drawn } else { nil } }, current: icons[key],
                               color: $navigation.iconColor, filled: $navigation.iconFilled,
                               pack: pack?.key == key ? pack?.icons : nil, problem: problem?.key == key ? problem?.text : nil,
                               choose: { model.store.setIcon($0, for: key) },
                               chooseFile: { chooseFile(for: key) }, pick: { name in pick(name, for: key) }, leavePack: { pack = nil })
                }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "car" else { return false }
            Task { await choose(url, for: key) }
            return true
        } isTargeted: { over in
            if over { dropping = key } else if dropping == key { dropping = nil }
        }
        .id(key)
    }

    /// What the row's tile wears, in words; a file it can't draw is marked, the reason listed above the section.
    private func wears(_ key: TileIconKey, icons: TileIcons, drawn: Bool) -> some View {
        let line = icons.entries.first { $0.key == key }?.line
        let text: Text = switch icons[key] {
        case nil: Text("Its own icon")
        case .app(let app): Text("\(apps.entry(app)?.name ?? TileIconKey.app(app).key)'s icon")
        case .picture(let icon): Text(icon.filled ? icon.picture.title : "\(icon.picture.title), unfilled")
        case .file(let path, _) where !drawn && apps.files.diagnostics.contains(where: { $0.line == line }):
            Text("\(Image(systemName: "exclamationmark.triangle.fill").renderingMode(.original)) \(IconPicker.file(path)) can't be used")
        case .file(let path, let name): Text(name.map { "\($0), from \(IconPicker.file(path))" } ?? IconPicker.file(path))
        }
        return text.font(.caption).foregroundStyle(.secondary)
    }

    private func name(_ key: TileIconKey) -> String {
        switch key {
        case .files: "Files"
        case .app(let app): apps.entry(app)?.name ?? key.key
        }
    }

    /// The tile's own icon: dock2's folder, for Files.
    private func ownIcon(_ key: TileIconKey) -> NSImage {
        switch key {
        case .files: apps.filesOwn
        case .app(let app): apps.entry(app)?.own ?? NSWorkspace.shared.icon(for: .application)
        }
    }

    /// A row's choices opened afresh from its icon or Change…: no pack open and nothing refused.
    private func open(_ key: TileIconKey) {
        pack = nil
        problem = nil
        navigation.icon = key
    }

    /// A row's choices opened, from the row or a tile's Change Icon…: its picture's colour and fill taken up, and
    /// the row brought into view.
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
                pack = (key, IconPack(url: url, hash: hash, icons: contents.icons.map { icon in
                    IconPack.Icon(name: icon, image: apps.files.shim(url, hash: hash, icon: icon).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                }))
                navigation.icon = key
            } else {
                _ = try contents.icon(named: nil)
                place(url, hash: hash, icon: nil, for: key)
            }
        } catch {
            problem = (key, "\(url.lastPathComponent) \(error.reason).")
            navigation.icon = key
        }
    }

    private func pick(_ icon: String, for key: TileIconKey) {
        guard let pack = pack?.key == key ? pack?.icons : nil else { return }
        place(pack.url, hash: pack.hash, icon: icon, for: key)
    }

    /// Copied beside the settings, so it travels with them and an emptied Downloads folder takes nothing.
    private func place(_ url: URL, hash: String, icon: String?, for key: TileIconKey) {
        do {
            let path = try TileIconFiles.place(url, hash: hash, in: model.store.file.folder)
            model.store.setIcon(.file(path: path, name: icon), for: key)
            pack = nil
        } catch {
            problem = (key, "\(url.lastPathComponent) could not be copied beside config.toml: \(error.localizedDescription)")
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

/// A row's choices: across the top its own icon — and for the Files tile, Finder's beside it — the file it wears, if
/// one, and Choose File… for an Icon Composer icon; below, Cairo's pictures with the colour and the fill. Once a
/// pack is chosen, its icons instead.
private struct IconPicker: View {
    let own: NSImage
    let ownTitle: String
    /// Finder's icon, offered where Finder's look is what someone may want: the Files tile.
    let finder: NSImage?
    /// The Icon Composer icon worn, drawn, if one is.
    let file: NSImage?
    let current: TileIcon?
    @Binding var color: IconColor
    @Binding var filled: Bool
    let pack: IconPack?
    let problem: String?
    let choose: (TileIcon?) -> Void
    let chooseFile: () -> Void
    let pick: (String) -> Void
    let leavePack: () -> Void

    /// Nine across holds Cairo's 59 pictures in seven rows, so the grid needs no scrolling.
    private static let columns = Array(repeating: GridItem(.fixed(IconCell.frame), spacing: IconCell.spacing), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pack { packChoices(pack) } else { choices }
            if let problem {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .frame(width: 9 * IconCell.frame + 8 * IconCell.spacing + 32)
    }

    @ViewBuilder private var choices: some View {
        HStack(spacing: IconCell.spacing) {
            IconCell(image: own, title: ownTitle, selected: current == nil) { choose(nil) }
            if let finder {
                IconCell(image: finder, title: "Finder", selected: current == .app(.finder)) { choose(.app(.finder)) }
            }
            if let file, case .file(let path, let name) = current {
                IconCell(image: file, title: name.map { "\($0), from \(Self.file(path))" } ?? Self.file(path), selected: true) {}
            }
            Spacer()
            Button("Choose File…", action: chooseFile)
                .help("An Icon Composer icon, compiled: the asset catalog (.car) actool builds")
        }
        Divider()
        LazyVGrid(columns: Self.columns, spacing: IconCell.spacing) {
            ForEach(CairoPicture.allCases, id: \.self) { picture in
                let icon = PictureIcon(picture: picture, color: color, filled: filled)
                IconCell(image: PictureIconImage.image(icon) ?? own, title: picture.title, selected: chosen == picture) { choose(.picture(icon)) }
            }
        }
        HStack {
            ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
            Spacer()
            Toggle("Fill", isOn: Binding(get: { filled }, set: { filled = $0; rechoose() }))
        }
        .disabled(chosen == nil)
    }

    @ViewBuilder private func packChoices(_ pack: IconPack) -> some View {
        HStack(spacing: 6) {
            Button(action: leavePack) { Image(systemName: "chevron.left").fontWeight(.semibold) }
                .buttonStyle(.borderless)
                .help("Back")
                .accessibilityLabel("Back")
            Text(pack.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
        }
        Divider()
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 10) {
                ForEach(pack.icons) { icon in
                    VStack(spacing: 2) {
                        IconCell(image: icon.image, title: icon.name, selected: { if case .file(_, icon.name?) = current { true } else { false } }()) {
                            pick(icon.name)
                        }
                        Text(icon.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A file's name, without the folder it is kept in.
    static func file(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
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

/// One choice of icon, drawn as a tile would wear it: a ring around the plate when it is the one worn, and a wash
/// under the pointer.
private struct IconCell: View {
    let image: NSImage
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// The icon's side. At 2× each of Cairo's pixels is two of the screen's for 54 of the 59 pictures.
    static let side: CGFloat = 40
    /// The cell's side: the icon and the ring around its plate.
    static let frame: CGFloat = 46
    static let spacing: CGFloat = 4

    /// The plate fills 412/512 of an icon; the ring keeps its corners concentric with the plate's.
    private static let shape = RoundedRectangle(cornerRadius: side * 412 / 512 * 0.225 + (frame - side * 412 / 512) / 2,
                                                style: .continuous)
    static var ring: some View {
        shape.strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: frame, height: frame)
    }

    var body: some View {
        Button(action: action) {
            Image(nsImage: image).resizable().frame(width: Self.side, height: Self.side)
                .frame(width: Self.frame, height: Self.frame)
                .background { Self.shape.fill(Color.primary.opacity(hovering && !selected ? 0.08 : 0)) }
                .overlay { if selected { Self.ring } }
                .contentShape(Self.shape)
                .contentShape(.focusEffect, Self.shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension TileIcons.Entry {
    var app: AppRef? {
        if case .app(let app) = key { app } else { nil }
    }
}
