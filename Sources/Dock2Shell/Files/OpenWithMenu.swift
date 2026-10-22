import AppKit
import Dock2System

/// Open With's submenu, Files' and search's: the default app, the rest by name, and pills below them that
/// make the app picked the one to open with from now on — for these files, or for all of their extension.
@MainActor
enum OpenWithMenu {
    /// `picked` is told an app was chosen, before the files open in it.
    static func fill(_ menu: MenuBuilder, for urls: [URL], picked: @escaping () -> Void) {
        let apps = OpenWith.apps(for: urls)
        let scopes = OpenWith.scopes(for: urls)
        let pills = MenuPills(label: "Remember for", titles: scopes.map { title($0, count: urls.count) })
        let preferred = urls.count == 1 && OpenWith.hasOwnApp(urls[0]) ? "this file" : "default"
        for app in [apps.preferred].compactMap({ $0 }) + apps.others {
            let name = OpenWith.name(app)
            let item = menu.item(app == apps.preferred ? "\(name) (\(preferred))" : name) {
                picked()
                open(urls, with: app, remembering: pills.selected.map { scopes[$0] })
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if app == apps.preferred, !apps.others.isEmpty { menu.separator() }
        }
        if apps.preferred == nil, apps.others.isEmpty {
            menu.item("None", enabled: false) {}
        } else if !scopes.isEmpty {
            menu.separator()
            menu.pills(pills)
        }
    }

    private static func title(_ scope: OpenWith.Scope, count: Int) -> String {
        switch scope {
        case .files: count == 1 ? "This File" : "These Files"
        case .type(let pathExtension): "All .\(pathExtension)"
        }
    }

    /// Remembered first, so that macOS's question about a type comes before the app's windows.
    private static func open(_ urls: [URL], with app: URL, remembering scope: OpenWith.Scope?) {
        let open = { NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        guard let scope else { return open() }
        Task {
            await OpenWith.remember(app, for: urls, scope)
            open()
        }
    }
}
