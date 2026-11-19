//
//  CGEventTabletBackend.swift
//  iPad Graphic Tablet — Mac
//
//  Generazione di VERI eventi tavoletta con le API pubbliche di
//  Quartz Event Services (CoreGraphics):
//
//   1. kCGEventTabletProximity — annuncia una penna (o gomma) "in prossimità"
//      con la maschera delle capacità (pressione, inclinazione, rotazione).
//   2. eventi mouse con sottotipo kCGEventMouseSubtypeTabletPoint, che portano
//      nei campi kCGTabletEvent* pressione, inclinazione, rotazione e coordinate
//      di tavoletta. AppKit li consegna alle app come NSEvent con
//      subtype == .tabletPoint e `pressure` valorizzata: è ciò che leggono
//      Photoshop, Affinity, Krita, Pixelmator…
//
//  È lo stesso percorso dei driver delle tavolette che "postano" eventi tablet
//  direttamente. Requisito: permesso Accessibilità (CGPreflightPostEventAccess).
//
//  Limite dichiarato: le API pubbliche non permettono di registrare un vero
//  dispositivo "Wacom". App che verificano la presenza del driver Wacom (es.
//  Illustrator) possono ignorare la pressione: vedi docs/FATTIBILITA.md.
//

import Foundation
import CoreGraphics

final class CGEventTabletBackend: InputBackend {

    let name = "Quartz Event Services (CGEvent tablet)"

    /// Maschere NX_TABLET_CAPABILITY_* (IOKit/hidsystem/IOLLEvent.h).
    private enum Capability {
        static let deviceID: Int64 = 0x0001
        static let absX: Int64 = 0x0002
        static let absY: Int64 = 0x0004
        static let buttons: Int64 = 0x0040
        static let tiltX: Int64 = 0x0080
        static let tiltY: Int64 = 0x0100
        static let pressure: Int64 = 0x0400
        static let rotation: Int64 = 0x2000
    }

    /// Identificativi del dispositivo virtuale. Configurabili da Impostazioni → Avanzate.
    var vendorID: Int64 = 0x1D1D
    var tabletID: Int64 = 0x0001
    var vendorPointerType: Int64 = 0x0802
    private let deviceID: Int64 = 0x4954   // "IT"
    private let pointerSerial: Int64 = 0x0001

    private let source: CGEventSource?
    private var lastPenLocation: CGPoint?
    private var tipDown = false
    private var eventNumber: Int64 = 0

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Nessuna soppressione degli eventi locali mentre postiamo.
        source?.localEventsSuppressionInterval = 0
    }

    var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: - Prossimità

    func proximity(entering: Bool, pointer: PointerKind, capabilities: DeviceCapabilities) {
        guard let e = CGEvent(source: source) else { return }
        e.type = .tabletProximity
        // Posizione esplicita: un evento "vuoto" avrebbe (0,0) e potrebbe far saltare il cursore.
        e.location = cursorLocation

        var mask = Capability.deviceID | Capability.absX | Capability.absY | Capability.buttons
        // Si dichiarano solo le capacità realmente rilevate sull'iPad.
        if capabilities.contains(.pressure) { mask |= Capability.pressure }
        if capabilities.contains(.tilt) { mask |= Capability.tiltX | Capability.tiltY }
        if capabilities.contains(.roll) { mask |= Capability.rotation }

        e.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: pointer == .eraser ? 2 : 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: tabletID)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPointerType)
        e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: pointerSerial)
        e.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: (vendorID << 32) | pointerSerial)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: mask)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: pointer.rawValue)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        e.post(tap: .cghidEventTap)

        if !entering {
            lastPenLocation = nil
            tipDown = false
        }
    }

    // MARK: - Penna

    func pen(_ phase: PenPhase, _ d: PenEventData, flags: CGEventFlags) {
        let type: CGEventType
        switch phase {
        case .hover: type = .mouseMoved
        case .down: type = .leftMouseDown
        case .drag: type = .leftMouseDragged
        case .up: type = .leftMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: d.location, mouseButton: .left) else { return }

        if phase == .down {
            eventNumber &+= 1
            tipDown = true
        }
        let isTipEvent = phase != .hover
        let pressure = isTipEvent && phase != .up ? d.pressure : 0

        e.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        e.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        e.setIntegerValueField(.mouseEventClickState, value: isTipEvent ? 1 : 0)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.deltaX.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.deltaY.rounded()))

        e.setIntegerValueField(.tabletEventPointX, value: d.tabletX)
        e.setIntegerValueField(.tabletEventPointY, value: d.tabletY)
        e.setIntegerValueField(.tabletEventPointZ, value: 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: (phase == .down || phase == .drag) ? 1 : 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: d.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: d.tiltY)
        e.setDoubleValueField(.tabletEventRotation, value: d.rotationDegrees)
        e.setDoubleValueField(.tabletEventTangentialPressure, value: 0)
        e.setIntegerValueField(.tabletEventDeviceID, value: deviceID)

        if !flags.isEmpty { e.flags = flags }
        e.post(tap: .cghidEventTap)

        if phase == .up { tipDown = false }
        lastPenLocation = d.location
    }

    // MARK: - Mouse (touchpad)

    func mouseMove(to point: CGPoint, delta: CGPoint, dragging: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        if !flags.isEmpty { e.flags = flags }
        e.post(tap: .cghidEventTap)
    }

    func mouseButton(_ button: CGMouseButton, down: Bool, at point: CGPoint, clickCount: Int, flags: CGEventFlags) {
        let type: CGEventType
        switch (button, down) {
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (.left, true): type = .leftMouseDown
        default: type = .leftMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button) else { return }
        if down { eventNumber &+= 1 }
        e.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        if !flags.isEmpty { e.flags = flags }
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double, flags: CGEventFlags, phase: ScrollPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        if !flags.isEmpty { e.flags = flags }
        // Scorrimento continuo (pixel precisi) con le fasi di un trackpad: rimbalzo elastico,
        // inerzia e gesti di navigazione delle app funzionano come con un trackpad vero.
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let field = CGEventField(rawValue: 99) {          // kCGScrollWheelEventScrollPhase
            e.setIntegerValueField(field, value: phase.scrollPhaseValue)
        }
        if let field = CGEventField(rawValue: 123) {         // kCGScrollWheelEventMomentumPhase
            e.setIntegerValueField(field, value: phase.momentumPhaseValue)
        }
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Tastiera

    func key(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        var f = flags
        // Le frecce di una tastiera Apple portano anche i flag "fn" e "tastierino": senza,
        // alcune scorciatoie di sistema (es. ⌃← / ⌃→ per gli Spaces) non scattano.
        if (123...126).contains(code) {
            f.insert(.maskSecondaryFn)
            f.insert(.maskNumericPad)
        }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }
}
