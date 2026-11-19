//
//  RegionSelector.swift
//  iPad Graphic Tablet — Mac
//
//  Selezione dell'area da mostrare sull'iPad: una velatura trasparente copre il
//  monitor scelto e si trascina un rettangolo (come lo screenshot di un'area).
//  Invio = tutto lo schermo · Esc = annulla.
//

import AppKit

final class RegionSelector {
    private static var active: RegionSelector?

    private let window: SelectionWindow
    private let completion: (NormRect?) -> Void

    /// Mostra la selezione sul monitor indicato. Il risultato è normalizzato rispetto
    /// al monitor (origine in alto a sinistra), nil se annullato.
    static func select(on display: DisplayInfo, aspectHint: Double?, completion: @escaping (NormRect?) -> Void) {
        active?.finish(nil)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        } ?? NSScreen.main
        guard let screen else { completion(nil); return }
        let selector = RegionSelector(screen: screen, aspectHint: aspectHint, completion: completion)
        active = selector
        selector.show()
    }

    private init(screen: NSScreen, aspectHint: Double?, completion: @escaping (NormRect?) -> Void) {
        self.completion = completion
        window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.aspectHint = aspectHint
        window.contentView = view
        view.onFinish = { [weak self] rect in self?.finish(rect) }
    }

    private func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSApp.activate()
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: NSRect?) {
        NSCursor.pop()
        window.orderOut(nil)
        RegionSelector.active = nil
        guard let rect, let size = window.contentView?.bounds.size, size.width > 0, size.height > 0 else {
            completion(nil)
            return
        }
        // Vista con origine in basso a sinistra → monitor con origine in alto a sinistra.
        let x: Double = Double(rect.minX / size.width)
        let y: Double = Double((size.height - rect.maxY) / size.height)
        let w: Double = Double(rect.width / size.width)
        let h: Double = Double(rect.height / size.height)
        completion(NormRect(x: Float(x), y: Float(y), width: Float(w), height: Float(h)).clamped())
    }
}

/// Le finestre senza bordo normalmente non ricevono la tastiera.
private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    /// Proporzioni dell'iPad: tenendo premuto Shift il rettangolo le rispetta.
    var aspectHint: Double?
    private var start: NSPoint?
    private var selection: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        var w: CGFloat = abs(p.x - start.x)
        var h: CGFloat = abs(p.y - start.y)
        if event.modifierFlags.contains(.shift), let aspect = aspectHint, aspect > 0 {
            // Vincolo alle proporzioni dell'iPad: l'immagine riempirà tutto lo schermo del tablet.
            let a = CGFloat(aspect)
            if w / max(h, 1) > a { h = w / a } else { w = h * a }
        }
        let x: CGFloat = p.x >= start.x ? start.x : start.x - w
        let y: CGFloat = p.y >= start.y ? start.y : start.y - h
        selection = NSRect(x: x, y: y, width: w, height: h).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selection, rect.width >= 40, rect.height >= 40 else {
            // Clic senza trascinare: nessuna selezione valida, si resta in attesa.
            selection = nil
            start = nil
            needsDisplay = true
            return
        }
        onFinish?(rect)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil)              // Esc
        case 36, 76: onFinish?(bounds)       // Invio: tutto lo schermo
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor.systemRed.setStroke()
            border.stroke()
            let label = "\(Int(rect.width)) × \(Int(rect.height)) pt"
            drawText(label, at: NSPoint(x: rect.minX + 8, y: rect.maxY + 8), size: 13)
        }
        let help = "Trascina per scegliere l'area da mostrare sull'iPad  ·  Shift = proporzioni dell'iPad  ·  Invio = tutto lo schermo  ·  Esc = annulla"
        drawText(help, at: NSPoint(x: 24, y: bounds.maxY - 48), size: 15)
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let textSize = string.size()
        let background = NSRect(x: point.x - 8, y: point.y - 4, width: textSize.width + 16, height: textSize.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        string.draw(at: point)
    }
}
