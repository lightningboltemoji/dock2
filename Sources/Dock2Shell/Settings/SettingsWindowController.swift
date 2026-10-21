import AppKit
import Dock2System
import SwiftUI

/// The one window dock2 leaves on the desktop. While it is open, dock2 is a regular app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private let actions: SettingsActions
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: SettingsModel, actions: SettingsActions) {
        self.model = model
        self.actions = actions
    }

    /// Opens the window, at `section` if given.
    func show(_ section: SettingsView.Section? = nil) {
        if let section { navigation.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        onVisibilityChange?(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(model: model, actions: actions, navigation: navigation))
        let window = NSWindow(contentViewController: host)
        window.title = "dock2 Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 720, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("Settings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        navigation.section = .general
        onVisibilityChange?(false)
    }
}

/// Which section the window shows: opened at one from outside — search's access row opens Permissions.
@MainActor
@Observable
final class SettingsNavigation {
    var section: SettingsView.Section? = .general
}
