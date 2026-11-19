//
//  KeyboardLayoutResolver.swift
//  iPad Graphic Tablet — Mac
//
//  Trova il tasto fisico che produce un certo carattere sul layout di
//  tastiera ATTIVO. Esempio: "[" su layout USA è un tasto diretto, su layout
//  italiano è ⌥+è. Senza questa traduzione le scorciatoie di Photoshop
//  ([ ] per la dimensione del pennello, ⌘+ per lo zoom…) sbaglierebbero tasto.
//
//  Le API Text Input Sources vanno chiamate sul main thread: la mappa viene
//  costruita lì e letta dalla coda del motore tramite lock.
//

import Foundation
import Carbon.HIToolbox
import CoreGraphics

final class KeyboardLayoutResolver {
    static let shared = KeyboardLayoutResolver()

    private let lock = NSLock()
    private var map: [String: (CGKeyCode, ModifierKeys)] = [:]
    private(set) var layoutName = "—"
    private var observer: NSObjectProtocol?

    private init() {}

    /// Da chiamare sul main thread all'avvio.
    func startObserving() {
        dispatchPrecondition(condition: .onQueue(.main))
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
    }

    /// Ricostruisce la mappa per il layout corrente (main thread).
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        var name = "—"
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            name = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        let newMap = buildMap(source)
        lock.lock()
        map = newMap
        layoutName = name
        lock.unlock()
        tlog.info("Tastiera: layout \"\(name)\", \(newMap.count) caratteri mappati")
    }

    private func buildMap(_ source: TISInputSource) -> [String: (CGKeyCode, ModifierKeys)] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var result: [String: (CGKeyCode, ModifierKeys)] = [:]
        let keyboardType = UInt32(LMGetKbdType())

        // Stati modificatore da provare, in ordine di preferenza (prima senza modificatori).
        let states: [(UInt32, ModifierKeys)] = [
            (0, []),
            (UInt32((shiftKey >> 8) & 0xFF), [.shift]),
            (UInt32((optionKey >> 8) & 0xFF), [.option]),
            (UInt32(((shiftKey | optionKey) >> 8) & 0xFF), [.shift, .option]),
        ]

        layoutData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for (state, mods) in states {
                for code in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), state,
                                                keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeyState, chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let s = String(utf16CodeUnits: chars, count: length)
                    if result[s] == nil {
                        result[s] = (CGKeyCode(code), mods)
                    }
                }
            }
        }
        return result
    }

    /// Risolve una combinazione nel codice tasto + flag da inviare. Thread-safe.
    func resolve(_ combo: KeyCombo) -> (code: CGKeyCode, flags: CGEventFlags)? {
        if let code = combo.keyCode {
            return (CGKeyCode(code), KeyboardLayoutResolver.flags(for: combo.modifiers))
        }
        guard let ch = combo.character, !ch.isEmpty else { return nil }
        lock.lock()
        let hit = map[ch] ?? map[ch.lowercased()]
        lock.unlock()
        let fallback = KeyboardLayoutResolver.ansiFallback[ch] ?? KeyboardLayoutResolver.ansiFallback[ch.lowercased()]
        guard let found = hit ?? fallback else { return nil }
        return (found.0, KeyboardLayoutResolver.flags(for: combo.modifiers.union(found.1)))
    }

    static func flags(for mods: ModifierKeys) -> CGEventFlags {
        var f: CGEventFlags = []
        if mods.contains(.command) { f.insert(.maskCommand) }
        if mods.contains(.shift) { f.insert(.maskShift) }
        if mods.contains(.option) { f.insert(.maskAlternate) }
        if mods.contains(.control) { f.insert(.maskControl) }
        if mods.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    static func modifiers(from flags: CGEventFlags) -> ModifierKeys {
        var m: ModifierKeys = []
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        return m
    }

    /// Ripiego per layout USA (usato solo se la mappa del layout attivo non ha il carattere).
    private static let ansiFallback: [String: (CGKeyCode, ModifierKeys)] = [
        "a": (0x00, []), "s": (0x01, []), "d": (0x02, []), "f": (0x03, []), "h": (0x04, []),
        "g": (0x05, []), "z": (0x06, []), "x": (0x07, []), "c": (0x08, []), "v": (0x09, []),
        "b": (0x0B, []), "q": (0x0C, []), "w": (0x0D, []), "e": (0x0E, []), "r": (0x0F, []),
        "y": (0x10, []), "t": (0x11, []), "1": (0x12, []), "2": (0x13, []), "3": (0x14, []),
        "4": (0x15, []), "6": (0x16, []), "5": (0x17, []), "=": (0x18, []), "+": (0x18, [.shift]),
        "9": (0x19, []), "7": (0x1A, []), "-": (0x1B, []), "8": (0x1C, []), "0": (0x1D, []),
        "]": (0x1E, []), "o": (0x1F, []), "u": (0x20, []), "[": (0x21, []), "i": (0x22, []),
        "p": (0x23, []), "l": (0x25, []), "j": (0x26, []), "'": (0x27, []), "k": (0x28, []),
        ";": (0x29, []), "\\": (0x2A, []), ",": (0x2B, []), "/": (0x2C, []), "n": (0x2D, []),
        "m": (0x2E, []), ".": (0x2F, []), "`": (0x32, []), " ": (0x31, []),
    ]
}
