//
//  PressureCurve.swift
//  TabletCore
//
//  Curva di pressione personalizzabile (Bézier cubica da (0,0) a (1,1),
//  come nei pannelli Wacom) con sensibilità minima/massima e soglia di click.
//

import Foundation

public struct CurvePoint: Codable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

public struct PressureCurve: Codable, Equatable, Hashable {
    /// Punti di controllo della Bézier (x vincolata a 0…1).
    public var control1: CurvePoint
    public var control2: CurvePoint
    /// Sensibilità minima: pressione grezza sotto la quale l'uscita è 0.
    public var minimumInput: Float
    /// Sensibilità massima: pressione grezza oltre la quale l'uscita è 1.
    public var maximumInput: Float
    /// Soglia di contatto: sotto questo valore grezzo la punta NON genera click
    /// (utile su iPad senza hover per spostare il cursore sfiorando lo schermo).
    public var tipThreshold: Float
    /// Pressione minima trasmessa mentre la punta è giù (evita tratti "vuoti").
    public var outputFloor: Float

    public init(control1: CurvePoint, control2: CurvePoint, minimumInput: Float = 0,
                maximumInput: Float = 1, tipThreshold: Float = 0, outputFloor: Float = 0.01) {
        self.control1 = control1
        self.control2 = control2
        self.minimumInput = minimumInput
        self.maximumInput = maximumInput
        self.tipThreshold = tipThreshold
        self.outputFloor = outputFloor
    }

    public static let linear = PressureCurve(control1: CurvePoint(x: 1.0 / 3, y: 1.0 / 3),
                                             control2: CurvePoint(x: 2.0 / 3, y: 2.0 / 3))
    /// Morbida: poca forza per tratti pieni (ritocco leggero, Pencil "dura").
    public static let soft = PressureCurve(control1: CurvePoint(x: 0.15, y: 0.45),
                                           control2: CurvePoint(x: 0.45, y: 0.9))
    /// Rigida: serve più forza per arrivare al massimo (controllo fine dell'opacità).
    public static let firm = PressureCurve(control1: CurvePoint(x: 0.55, y: 0.1),
                                           control2: CurvePoint(x: 0.9, y: 0.55))

    /// Applica sensibilità e curva alla pressione grezza 0…1.
    public func apply(_ raw: Float) -> Float {
        guard raw.isFinite else { return 0 }
        let lo = min(max(minimumInput, 0), 0.95)
        let hi = max(min(maximumInput, 1), lo + 0.05)
        let n = min(max((raw - lo) / (hi - lo), 0), 1)
        return min(max(bezierY(forX: n), 0), 1)
    }

    /// Pressione da trasmettere quando la punta è a contatto.
    public func contactPressure(_ raw: Float) -> Float {
        max(apply(raw), outputFloor)
    }

    /// La pressione grezza supera la soglia di click?
    public func isTipDown(_ raw: Float) -> Bool {
        raw > tipThreshold
    }

    /// Punti campionati per disegnare il grafico nell'interfaccia.
    public func sampled(count: Int = 64) -> [CurvePoint] {
        guard count > 1 else { return [] }
        return (0..<count).map { i in
            let x = Float(i) / Float(count - 1)
            return CurvePoint(x: x, y: apply(x))
        }
    }

    // MARK: Bézier

    private func bezier(_ t: Float, _ p1: Float, _ p2: Float) -> Float {
        // Termini separati: la versione su una riga è troppo pesante per il type-checker.
        let u: Float = 1 - t
        let a: Float = 3 * u * u * t
        let b: Float = 3 * u * t * t
        let c: Float = t * t * t
        return a * p1 + b * p2 + c
    }

    /// Risolve t tale che x(t) = x con bisezione (robusta e sufficiente a 240 Hz),
    /// poi restituisce y(t).
    private func bezierY(forX x: Float) -> Float {
        let c1x = min(max(control1.x, 0), 1)
        let c2x = min(max(control2.x, 0), 1)
        var lo: Float = 0
        var hi: Float = 1
        var t = x
        for _ in 0..<24 {
            let bx = bezier(t, c1x, c2x)
            if abs(bx - x) < 1e-5 { break }
            if bx < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return bezier(t, control1.y, control2.y)
    }
}
