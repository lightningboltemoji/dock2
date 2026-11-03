import AppKit
import Carbon.HIToolbox
import Dock2Core
import SwiftUI

/// A field that records the next chord typed into it, at a control's size, so a Form row keeps it beside its
/// label and on the label's baseline. A global shortcut takes its chord from every app, so only chords that
/// type nothing are taken: with ⌘ or ⌃, or a function key.
struct ShortcutRecorder: View {
    @Binding var chord: KeyChord?

    var body: some View {
        // SwiftUI reads no baseline from an NSView: from the field's middle to its text's, as `RecorderView` draws it.
        let baseline = (RecorderView.font.ascender + RecorderView.font.descender) / 2
        Field(chord: $chord)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baseline }
            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + baseline }
    }

    /// Whether `chord` can be a global shortcut: one the config file can spell, that types nothing.
    static func isAcceptable(_ chord: KeyChord) -> Bool {
        guard chord.spelled != nil else { return false }
        let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        return chord.modifiers & (KeyChord.command | KeyChord.control) != 0 || functionKeys.contains(Int(chord.keyCode))
    }
}

private struct Field: NSViewRepresentable {
    @Binding var chord: KeyChord?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { chord = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.chord = chord
        view.onRecord = { chord = $0 }
    }

    /// Its own size whatever it is offered: a representable otherwise takes all of a Form row's width, and the
    /// row puts it under its label.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderView, context: Context) -> CGSize? {
        RecorderView.size
    }
}

private final class RecorderView: NSView {
    static let size = CGSize(width: 150, height: 22)
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    var chord: KeyChord? { didSet { needsDisplay = true } }
    var onRecord: ((KeyChord?) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case kVK_Escape:
            recording = false
        case kVK_Delete, kVK_ForwardDelete:
            recording = false
            onRecord?(nil)
        default:
            let new = KeyChord(keyCode: UInt32(event.keyCode), modifiers: KeyChord.carbonModifiers(event.modifierFlags))
            guard ShortcutRecorder.isAcceptable(new) else {
                NSSound.beep()
                return
            }
            recording = false
            onRecord?(new)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘-chords arrive here before keyDown; while recording they are the shortcut, not a menu's.
        guard recording, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? "Type a shortcut…" : chord?.displayName ?? "Click to record"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: chord == nil && !recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        // Centred on its line, the baseline where `ShortcutRecorder` tells SwiftUI it is.
        let baseline = bounds.midY - (Self.font.ascender + Self.font.descender) / 2
        text.draw(with: CGRect(x: (bounds.width - size.width) / 2, y: baseline, width: size.width, height: size.height),
                  attributes: attributes)
    }
}
