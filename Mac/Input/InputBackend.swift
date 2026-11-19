//
//  InputBackend.swift
//  iPad Graphic Tablet — Mac
//
//  Interfaccia del livello che "inietta" l'input nel sistema.
//  Implementazione attuale: CGEventTabletBackend (Quartz Event Services,
//  API pubbliche). L'interfaccia è pensata per poter aggiungere in futuro un
//  backend basato su dispositivo HID virtuale (CoreHID / DriverKit) senza
//  toccare motore, rete o interfaccia: vedi docs/FATTIBILITA.md §4.
//

import Foundation
import CoreGraphics

/// Tipo di puntatore annunciato agli eventi di prossimità (NSPointingDeviceType).
enum PointerKind: Int64 {
    case pen = 1
    case eraser = 3
}

enum PenPhase {
    case hover   // penna sospesa: solo spostamento
    case down    // punta appoggiata
    case drag    // punta appoggiata in movimento
    case up      // punta sollevata
}

/// Dati di un evento penna già mappati sullo schermo del Mac.
struct PenEventData {
    /// Posizione nello spazio globale Quartz (origine in alto a sinistra del monitor principale).
    var location: CGPoint
    /// Pressione finale 0…1 (curva già applicata).
    var pressure: Double
    /// Inclinazione −1…1 sugli assi dello schermo.
    var tiltX: Double
    var tiltY: Double
    /// Rotazione sull'asse in gradi (Apple Pencil Pro).
    var rotationDegrees: Double
    /// Coordinate assolute "di tavoletta" (risoluzione della superficie iPad).
    var tabletX: Int64
    var tabletY: Int64
    /// Spostamento rispetto all'evento precedente (per le app che leggono i delta).
    var deltaX: Double
    var deltaY: Double
}

protocol InputBackend: AnyObject {
    /// Nome mostrato nella diagnostica.
    var name: String { get }

    /// Annuncia ingresso/uscita della penna dal raggio della tavoletta.
    func proximity(entering: Bool, pointer: PointerKind, capabilities: DeviceCapabilities)

    /// Evento penna (movimento, punta giù/su) con pressione e inclinazione.
    func pen(_ phase: PenPhase, _ data: PenEventData, flags: CGEventFlags)

    /// Mouse "normale" (modalità touchpad).
    func mouseMove(to point: CGPoint, delta: CGPoint, dragging: Bool, flags: CGEventFlags)
    func mouseButton(_ button: CGMouseButton, down: Bool, at point: CGPoint, clickCount: Int, flags: CGEventFlags)
    /// Scorrimento in pixel con le fasi di un trackpad (inizio, cambio, fine, inerzia):
    /// le app lo trattano come uno scorrimento continuo e fluido.
    func scroll(dx: Double, dy: Double, flags: CGEventFlags, phase: ScrollPhase)

    /// Tastiera.
    func key(code: CGKeyCode, down: Bool, flags: CGEventFlags)

    /// Posizione attuale del cursore (spazio globale Quartz).
    var cursorLocation: CGPoint { get }
}

/// Fase di uno scorrimento "da trackpad" (campi pubblici kCGScrollWheelEventScrollPhase / MomentumPhase).
enum ScrollPhase {
    case began, changed, ended
    case momentumBegan, momentumChanged, momentumEnded

    /// Valore di kCGScrollWheelEventScrollPhase (CGScrollPhase).
    var scrollPhaseValue: Int64 {
        switch self {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        case .momentumBegan, .momentumChanged, .momentumEnded: return 0
        }
    }

    /// Valore di kCGScrollWheelEventMomentumPhase (CGMomentumScrollPhase).
    var momentumPhaseValue: Int64 {
        switch self {
        case .momentumBegan: return 1
        case .momentumChanged: return 2
        case .momentumEnded: return 3
        case .began, .changed, .ended: return 0
        }
    }
}
