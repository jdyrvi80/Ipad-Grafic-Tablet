//
//  Geometry.swift
//  TabletCore
//
//  Tipi geometrici e funzioni di mapping usate da ENTRAMBE le app:
//  l'iPad le usa per disegnare l'area attiva, il Mac per convertire
//  le coordinate. Avere un'unica implementazione evita discrepanze.
//

import Foundation

/// Modalità di utilizzo (sezione 4 delle specifiche).
public enum TabletMode: UInt8, Codable, CaseIterable, Identifiable {
    case tablet = 0      // A: schermo nero, movimento relativo
    case screen = 1      // B: superficie proporzionale al monitor, coordinate assolute
    case photoshop = 2   // C: schermo nero, assoluto, barra strumenti di ritocco
    case touchpad = 3    // D: dito come mouse, Pencil come penna
    case display = 4     // E: l'iPad mostra lo schermo del Mac (o un'area) e la penna disegna sopra

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .tablet: return "Tavoletta"
        case .screen: return "Schermo"
        case .photoshop: return "Photoshop"
        case .touchpad: return "Trackpad"
        case .display: return "Display"
        }
    }

    public var summary: String {
        switch self {
        case .tablet: return "Schermo nero, cursore relativo come una tavoletta in modalità mouse"
        case .screen: return "Area proporzionale al monitor, la penna punta in coordinate assolute"
        case .photoshop: return "Schermo nero, mapping assoluto, barra rapida per il ritocco"
        case .touchpad: return "L'iPad è un trackpad con i gesti di macOS; la Pencil funziona come una tavoletta sul monitor"
        case .display: return "L'iPad mostra lo schermo del Mac o un'area scelta: la penna disegna sull'immagine"
        }
    }

    /// Mapping predefinito della penna per la modalità.
    public var defaultPenMapping: PenMapping {
        switch self {
        case .tablet: return .relative
        case .screen, .photoshop, .touchpad, .display: return .absolute
        }
    }

    /// Se il dito è attivo come puntatore.
    public var fingerIsPointer: Bool { self == .touchpad }

    /// Modalità disponibili nell'app: Display e Trackpad (le altre restano solo per compatibilità).
    public static let available: [TabletMode] = [.display, .touchpad]
}

// MARK: - Trackpad: opzioni come in Impostazioni di Sistema → Trackpad

/// Numero di dita per un gesto di sistema (o disattivato).
public enum GestureFingers: Int, Codable, CaseIterable, Identifiable {
    case off = 0
    case three = 3
    case four = 4
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .off: return "No"
        case .three: return "Tre dita"
        case .four: return "Quattro dita"
        }
    }
}

/// Clic secondario (clic destro).
public enum SecondaryClickMode: String, Codable, CaseIterable, Identifiable {
    case twoFingers, bottomRight, bottomLeft, off
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .twoFingers: return "Tocca con due dita"
        case .bottomRight: return "Tocca nell'angolo in basso a destra"
        case .bottomLeft: return "Tocca nell'angolo in basso a sinistra"
        case .off: return "No"
        }
    }

    /// Un tocco in questa posizione (normalizzata 0…1) è un clic secondario?
    public func isSecondary(u: Double, v: Double) -> Bool {
        switch self {
        case .bottomRight: return u > 0.8 && v > 0.75
        case .bottomLeft: return u < 0.2 && v > 0.75
        case .twoFingers, .off: return false
        }
    }
}

/// Opzioni del trackpad, con i nomi e i valori predefiniti di macOS dove possibile.
public struct TrackpadOptions: Codable, Equatable, Hashable {
    // Punta e clic
    public var secondaryClick: SecondaryClickMode = .twoFingers
    /// Ricerca e rilevatori dati: tocco con tre dita (⌃⌘D).
    public var lookUpThreeFingerTap = true
    /// Trascinamento: tieni premuto un dito e poi muovilo.
    public var holdToDrag = true
    /// Trascinamento con tre dita (opzione di Accessibilità di macOS).
    public var threeFingerDrag = false
    // Scorrimento e zoom
    public var naturalScrolling = true
    /// Lo scorrimento continua per inerzia dopo aver sollevato le dita.
    public var scrollInertia = true
    /// Pizzico con due dita = zoom (scorciatoie ⌘+ / ⌘−, vedi Pencil e gesti).
    public var pinchToZoom = true
    // Altri gesti
    /// Scorri tra le pagine (⌘[ / ⌘]).
    public var swipeBetweenPages: GestureFingers = .off
    /// Scorri tra le app a tutto schermo / Spaces (⌃← / ⌃→).
    public var swipeBetweenSpaces: GestureFingers = .three
    /// Mission Control: scorri verso l'alto.
    public var missionControl: GestureFingers = .three
    /// Exposé app: scorri verso il basso.
    public var appExpose: GestureFingers = .off
    /// Launchpad / App: pizzico con pollice e tre dita.
    public var launchpad = true
    /// Mostra scrivania: allarga pollice e tre dita.
    public var showDesktop = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case secondaryClick, lookUpThreeFingerTap, holdToDrag, threeFingerDrag, naturalScrolling, scrollInertia,
             pinchToZoom, swipeBetweenPages, swipeBetweenSpaces, missionControl, appExpose, launchpad, showDesktop
    }

    /// Decodifica tollerante: le opzioni mancanti prendono il valore predefinito.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrackpadOptions()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            let decoded: T? = try? c.decodeIfPresent(T.self, forKey: key)
            return decoded ?? fallback
        }
        secondaryClick = value(.secondaryClick, d.secondaryClick)
        lookUpThreeFingerTap = value(.lookUpThreeFingerTap, d.lookUpThreeFingerTap)
        holdToDrag = value(.holdToDrag, d.holdToDrag)
        threeFingerDrag = value(.threeFingerDrag, d.threeFingerDrag)
        naturalScrolling = value(.naturalScrolling, d.naturalScrolling)
        scrollInertia = value(.scrollInertia, d.scrollInertia)
        pinchToZoom = value(.pinchToZoom, d.pinchToZoom)
        swipeBetweenPages = value(.swipeBetweenPages, d.swipeBetweenPages)
        swipeBetweenSpaces = value(.swipeBetweenSpaces, d.swipeBetweenSpaces)
        missionControl = value(.missionControl, d.missionControl)
        appExpose = value(.appExpose, d.appExpose)
        launchpad = value(.launchpad, d.launchpad)
        showDesktop = value(.showDesktop, d.showDesktop)
    }
}

/// Mapping della penna verso il cursore.
public enum PenMapping: String, Codable, CaseIterable, Identifiable {
    case absolute
    case relative
    public var id: String { rawValue }
    public var title: String { self == .absolute ? "Assoluto (penna)" : "Relativo (mouse)" }
}

/// Modalità Display: cosa fanno due dita sull'iPad.
public enum DisplayGestureTarget: String, Codable, CaseIterable, Identifiable {
    /// Pizzico = zoom dell'area mostrata, trascinamento = spostamento dell'area.
    case area
    /// Pizzico e trascinamento vanno all'app in primo piano (zoom con le scorciatoie, scorrimento).
    case app
    public var id: String { rawValue }
    public var title: String { self == .area ? "Zoom e spostamento dell'area" : "Zoom e scorrimento nell'app" }
}

/// Capacità hardware rilevate DAVVERO sull'iPad (mai presunte dal modello).
public struct DeviceCapabilities: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// La pressione varia realmente durante i tratti (assente su Apple Pencil USB-C).
    public static let pressure = DeviceCapabilities(rawValue: 1 << 0)
    /// Altitudine/azimut disponibili.
    public static let tilt = DeviceCapabilities(rawValue: 1 << 1)
    /// Hover della penna ricevuto almeno una volta.
    public static let hover = DeviceCapabilities(rawValue: 1 << 2)
    /// Rotazione sull'asse (Apple Pencil Pro) osservata.
    public static let roll = DeviceCapabilities(rawValue: 1 << 3)
    /// Doppio tocco ricevuto almeno una volta.
    public static let doubleTap = DeviceCapabilities(rawValue: 1 << 4)
    /// Squeeze ricevuto almeno una volta (Apple Pencil Pro, iPadOS 17.5+).
    public static let squeeze = DeviceCapabilities(rawValue: 1 << 5)
    /// Multitouch con le dita.
    public static let multitouch = DeviceCapabilities(rawValue: 1 << 6)
    /// Il client sa mostrare i fotogrammi dello schermo del Mac (modalità Display).
    public static let videoDisplay = DeviceCapabilities(rawValue: 1 << 7)
    /// API disponibili nel sistema per hover/squeeze/roll (non implica hardware presente).
    public static let osSupportsHover = DeviceCapabilities(rawValue: 1 << 8)
    public static let osSupportsSqueeze = DeviceCapabilities(rawValue: 1 << 9)

    public var descriptionIT: [String] {
        var out: [String] = []
        if contains(.pressure) { out.append("Pressione") }
        if contains(.tilt) { out.append("Inclinazione") }
        if contains(.hover) { out.append("Hover") }
        if contains(.roll) { out.append("Rotazione") }
        if contains(.doubleTap) { out.append("Doppio tocco") }
        if contains(.squeeze) { out.append("Squeeze") }
        if contains(.multitouch) { out.append("Multitouch") }
        return out
    }
}

/// Rettangolo normalizzato (0…1).
public struct NormRect: Codable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)

    public var maxX: Float { x + width }
    public var maxY: Float { y + height }

    /// Riporta il rettangolo dentro 0…1 con dimensione minima 5%.
    public func clamped() -> NormRect {
        let w = min(max(width, 0.05), 1)
        let h = min(max(height, 0.05), 1)
        let nx = min(max(x, 0), 1 - w)
        let ny = min(max(y, 0), 1 - h)
        return NormRect(x: nx, y: ny, width: w, height: h)
    }

    public func encode(into w: inout ByteWriter) {
        w.f32(x); w.f32(y); w.f32(width); w.f32(height)
    }

    public static func decode(from r: inout ByteReader) throws -> NormRect {
        NormRect(x: try r.f32(), y: try r.f32(), width: try r.f32(), height: try r.f32())
    }
}

/// Rotazione della tavoletta a quarti di giro (0°, 90°, 180°, 270°).
public enum QuarterTurn {
    /// Ruota un punto normalizzato.
    /// k=1: (x,y)→(y, 1−x) · k=2: (1−x, 1−y) · k=3: (1−y, x)
    @inline(__always)
    public static func rotatePoint(_ x: Double, _ y: Double, turns: Int) -> (Double, Double) {
        switch ((turns % 4) + 4) % 4 {
        case 1: return (y, 1 - x)
        case 2: return (1 - x, 1 - y)
        case 3: return (1 - y, x)
        default: return (x, y)
        }
    }

    /// Ruota un vettore direzione (stessa convenzione di rotatePoint).
    @inline(__always)
    public static func rotateVector(_ dx: Double, _ dy: Double, turns: Int) -> (Double, Double) {
        switch ((turns % 4) + 4) % 4 {
        case 1: return (dy, -dx)
        case 2: return (-dx, -dy)
        case 3: return (-dy, dx)
        default: return (dx, dy)
        }
    }

    /// Rotazione inversa di un punto.
    @inline(__always)
    public static func inversePoint(_ x: Double, _ y: Double, turns: Int) -> (Double, Double) {
        rotatePoint(x, y, turns: 4 - (((turns % 4) + 4) % 4))
    }
}

/// Calcolo dell'area di input effettiva.
public enum InputArea {

    /// Rettangolo (nello spazio RUOTATO) usato per il mapping.
    /// - Parameters:
    ///   - activeArea: area attiva scelta dall'utente (spazio ruotato, normalizzata).
    ///   - rotatedAspect: rapporto larghezza/altezza fisico della superficie dopo la rotazione.
    ///   - targetAspect: rapporto del monitor di destinazione (nil = non vincolare).
    public static func effectiveRect(activeArea: NormRect,
                                     rotatedAspect: Double,
                                     targetAspect: Double?) -> NormRect {
        let area = activeArea.clamped()
        guard let target = targetAspect, target > 0, rotatedAspect > 0 else { return area }
        // Rapporto fisico dell'area attiva.
        let areaAspect = Double(area.width) * rotatedAspect / Double(area.height)
        var w = Double(area.width)
        var h = Double(area.height)
        if areaAspect > target {
            // Area più larga del monitor: si restringe la larghezza.
            w = Double(area.height) * target / rotatedAspect
        } else {
            // Area più alta del monitor: si restringe l'altezza.
            h = Double(area.width) * rotatedAspect / target
        }
        let cx = Double(area.x) + Double(area.width) / 2
        let cy = Double(area.y) + Double(area.height) / 2
        let originX: Double = cx - w / 2
        let originY: Double = cy - h / 2
        return NormRect(x: Float(originX), y: Float(originY), width: Float(w), height: Float(h))
    }

    /// Stesso rettangolo riportato nelle coordinate NON ruotate dell'iPad,
    /// così l'app iPad può disegnarlo senza conoscere la logica di rotazione.
    public static func unrotated(_ rect: NormRect, turns: Int) -> NormRect {
        let corners = [
            QuarterTurn.inversePoint(Double(rect.x), Double(rect.y), turns: turns),
            QuarterTurn.inversePoint(Double(rect.maxX), Double(rect.y), turns: turns),
            QuarterTurn.inversePoint(Double(rect.x), Double(rect.maxY), turns: turns),
            QuarterTurn.inversePoint(Double(rect.maxX), Double(rect.maxY), turns: turns),
        ]
        let xs = corners.map { $0.0 }
        let ys = corners.map { $0.1 }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        return NormRect(x: Float(minX), y: Float(minY), width: Float(maxX - minX), height: Float(maxY - minY))
    }
}

// MARK: - Modalità Display: zoom e spostamento dell'area mostrata

/// Calcoli dell'area del monitor mostrata sull'iPad (coordinate normalizzate sul monitor).
/// Usati dal Mac per i gesti a due dita e dai client per disegnare i fotogrammi.
public enum DisplayViewport {
    /// Lato minimo dell'area (frazione del monitor): limite d'ingrandimento.
    public static let minSide: Double = 0.04

    /// Sposta l'area di (dx, dy) frazioni del monitor, senza uscire dal monitor.
    public static func pan(_ r: NormRect, dx: Double, dy: Double) -> NormRect {
        let w = Double(r.width)
        let h = Double(r.height)
        let x = clampOrigin(Double(r.x) + dx, size: w)
        let y = clampOrigin(Double(r.y) + dy, size: h)
        return NormRect(x: Float(x), y: Float(y), width: Float(w), height: Float(h))
    }

    /// Zoom attorno a un punto fisso.
    /// - scale: > 1 ingrandisce (l'area si restringe), < 1 riduce.
    /// - anchorX/anchorY: punto che resta sotto le dita, in frazioni dell'area (0…1).
    /// - fillAspect: proporzioni (larghezza/altezza, in coordinate normalizzate sul monitor)
    ///   con cui l'area riempirebbe l'iPad; il lato corto si allarga verso queste proporzioni
    ///   quando il monitor lo permette, così spariscono le bande nere.
    public static func zoom(_ r: NormRect, scale: Double, anchorX: Double, anchorY: Double,
                            fillAspect: Double?) -> NormRect {
        guard scale.isFinite, scale > 0 else { return r }
        let w0 = Double(r.width)
        let h0 = Double(r.height)
        let ax = min(max(anchorX, 0), 1)
        let ay = min(max(anchorY, 0), 1)
        // Punto del monitor sotto le dita: deve restare fermo.
        let px = Double(r.x) + ax * w0
        let py = Double(r.y) + ay * h0

        var s = scale
        if s > 1 {
            let room = min(w0, h0) / minSide
            s = min(s, max(room, 1))
        }
        // Mai oltre il monitor: alla massima riduzione si vede tutto lo schermo.
        var w = min(w0 / s, 1)
        var h = min(h0 / s, 1)
        if let k = fillAspect, k.isFinite, k > 0 {
            if w / h < k {
                w = min(k * h, 1)
            } else if w / h > k {
                h = min(w / k, 1)
            }
        }
        let x = clampOrigin(px - ax * w, size: w)
        let y = clampOrigin(py - ay * h, size: h)
        return NormRect(x: Float(x), y: Float(y), width: Float(w), height: Float(h))
    }

    /// Posizione di un fotogramma (area `frame`) dentro la vista che mostra l'area `view`,
    /// in frazioni della vista. Coincide con `.full` quando le due aree sono uguali.
    public static func placement(frame f: NormRect, view v: NormRect) -> NormRect {
        let vw = max(Double(v.width), 1e-6)
        let vh = max(Double(v.height), 1e-6)
        let x = (Double(f.x) - Double(v.x)) / vw
        let y = (Double(f.y) - Double(v.y)) / vh
        let w = Double(f.width) / vw
        let h = Double(f.height) / vh
        return NormRect(x: Float(x), y: Float(y), width: Float(w), height: Float(h))
    }

    private static func clampOrigin(_ o: Double, size: Double) -> Double {
        min(max(o, 0), max(1 - size, 0))
    }
}
