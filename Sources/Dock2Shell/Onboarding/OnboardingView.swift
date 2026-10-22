import Dock2Core
import Dock2System
import SwiftUI

/// What the first launch collected. Nothing is applied until its last page.
struct OnboardingChoices {
    var summon: Shortcut = .none
    var fileAccess: FileAccessChoice = .notAsked
    var showInFinder = true
    var clipboard = false
    var openAtLogin = false
}

/// The first launch, page by page ([onboarding](product/onboarding.md)).
struct OnboardingView: View {
    let dock: SystemDockSettings
    let preview: () -> NSView
    let finish: (OnboardingChoices) -> Void
    let quit: () -> Void

    @State private var page = 0
    @State private var choices = OnboardingChoices()
    @State private var recording: KeyChord?
    @State private var choosingChord = false

    private static let pages = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Step \(page + 1) of \(Self.pages)").font(.caption).foregroundStyle(.secondary)
            Group {
                switch page {
                case 0: welcome
                case 1: yourDock
                case 2: summon
                case 3: files
                case 4: clipboard
                case 5: login
                default: howItWorks
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(32)
        .frame(width: 620, height: 440)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title.weight(.semibold))
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { Spacer(); content() }.controlSize(.large)
    }

    private func next() { page += 1 }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Dock2 replaces the Dock while it runs.")
            Text("The Dock's settings are saved first and come back when Dock2 quits — even if it crashes or is killed.")
            Spacer()
            buttons {
                Button("Quit", action: quit)
                Button("Continue", action: next).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var yourDock: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Your dock")
            Text("Dock2 starts with the Dock's apps and size: \(dock.pinned.count) apps, size \(Int(dock.tileSize))\(dock.autohide ? ", hiding automatically" : "").")
            PreviewHost(make: preview).frame(maxWidth: .infinity, minHeight: 150)
            Spacer()
            buttons { Button("Continue", action: next).keyboardShortcut(.defaultAction) }
        }
    }

    private var summon: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Open Dock2 with ⌘Space?")
            Text("Spotlight's shortcut is switched off while Dock2 runs, and back on when it quits.")
            if choosingChord {
                HStack {
                    Text("Shortcut:")
                    ShortcutRecorder(chord: $recording).frame(width: 180)
                }
            }
            Spacer()
            buttons {
                Button("Not now") { choices.summon = .none; next() }
                if choosingChord {
                    Button("Use This Shortcut") { choices.summon = recording.map { .chord($0) } ?? .none; next() }
                        .disabled(recording == nil)
                } else {
                    Button("Choose Another…") { choosingChord = true }
                }
                Button("Use ⌘Space") { choices.summon = .commandSpace; next() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Your files")
            Text("Dock2 shows and finds your files. Full Disk Access lets it see all of them; macOS has no prompt for it, so the switch is in System Settings.")
            Toggle("Open “Show in Finder” from other apps in Dock2", isOn: $choices.showInFinder)
            Spacer()
            buttons {
                Button("Not now") { choices.fileAccess = .declined; next() }
                Button("Just Desktop, Documents and Downloads") {
                    choices.fileAccess = .folders
                    FileAccess.requestFolders { _ in }
                    next()
                }
                Button("Open System Settings") {
                    choices.fileAccess = .fullDisk
                    NSWorkspace.shared.open(FileAccess.fullDiskAccessPane)
                    next()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Clipboard history")
            Text("Keep what you copy — on this Mac, encrypted, for 30 days? Passwords are never kept.")
            Spacer()
            buttons {
                Button("No Thanks") { choices.clipboard = false; next() }
                Button("Keep History") { choices.clipboard = true; next() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Open at login?")
            Text("Dock2 can start when you log in, so the Dock you see is always this one.")
            Spacer()
            buttons {
                Button("Not Now") { choices.openAtLogin = false; next() }
                Button("Open at Login") { choices.openAtLogin = true; next() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("How it works")
            VStack(alignment: .leading, spacing: 8) {
                Text("Reveal the dock with the pointer, or press your shortcut — then type.")
                Text("⌘1 to ⌘9 open the first nine apps on the dock.")
                Text("Esc steps back.")
            }
            Spacer()
            buttons { Button("Start Dock2") { finish(choices) }.keyboardShortcut(.defaultAction) }
        }
    }
}

/// Hosts an AppKit view — the dock's preview, glass and all.
private struct PreviewHost: NSViewRepresentable {
    let make: () -> NSView
    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ view: NSView, context: Context) {}
}
