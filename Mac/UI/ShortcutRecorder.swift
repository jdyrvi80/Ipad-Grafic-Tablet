//
//  ShortcutRecorder.swift
//  iPad Graphic Tablet — Mac
//
//  Campo che registra una combinazione premuta sulla tastiera del Mac.
//  Salva il codice del tasto FISICO: funziona con qualsiasi layout
//  (italiano incluso) esattamente come lo premi tu.
//

import SwiftUI
import AppKit

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.combo = combo
        v.onRecord = { combo = $0 }
        return v
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.combo = combo
        nsView.onRecord = { combo = $0 }
        nsView.needsDisplay = true
    }
}

final class RecorderView: NSView {
    var combo = KeyCombo()
    var onRecord: ((KeyCombo) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }
    private var pendingModifier: (code: UInt16, flags: NSEvent.ModifierFlags)?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 26) }

    override func mouseDown(with event: NSEvent) {
        recording = true
        pendingModifier = nil
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Esc senza modificatori annulla la registrazione.
        if event.keyCode == MacKeyCode.escape && flags.subtracting(.capsLock).isEmpty {
            recording = false
            return
        }
        var character: String?
        if let ch = event.charactersIgnoringModifiers?.lowercased(), RecorderView.isPrintable(ch) {
            character = ch
        }
        let recorded = KeyCombo(keyCode: event.keyCode, character: character,
                                modifiers: RecorderView.modifiers(from: flags))
        pendingModifier = nil
        recording = false
        onRecord?(recorded)
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
        if !flags.isEmpty {
            pendingModifier = (event.keyCode, flags)
        } else if let p = pendingModifier {
            // Modificatore premuto e rilasciato da solo → pulsante "tieni premuto" (Alt, Shift…).
            pendingModifier = nil
            recording = false
            onRecord?(KeyCombo(keyCode: p.code, character: nil, modifiers: RecorderView.modifiers(from: p.flags)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill: NSColor = recording ? NSColor.systemRed.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.06)
        let stroke: NSColor = recording ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.2)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        if recording {
            text = "Premi la combinazione…"
        } else if combo.keyCode == nil && combo.character == nil {
            text = "Clicca per registrare"
        } else {
            text = combo.displayName
        }
        let textColor: NSColor = recording ? NSColor.white : NSColor.white.withAlphaComponent(0.85)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: attrs)
    }

    static func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty, s != " " else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
            !(0xF700...0xF8FF).contains(scalar.value)   // tasti funzione / frecce (area privata)
        }
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> ModifierKeys {
        var m: ModifierKeys = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }
}
