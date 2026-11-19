//
//  Stabilizer.swift
//  TabletCore
//
//  Riduzione del tremolio con filtro "1€" (Casiez, Roussel, Vogel — CHI 2012):
//  filtra molto quando la penna è lenta (tremolio, ritocco di precisione)
//  e quasi nulla quando è veloce (nessun ritardo percepibile nei tratti rapidi).
//

import Foundation

public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double

    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func reset() {
        lastValue = nil
        lastTime = nil
        lastDerivative = 0
    }

    @inline(__always)
    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public mutating func filter(_ value: Double, time: Double) -> Double {
        guard let prev = lastValue, let prevTime = lastTime else {
            lastValue = value
            lastTime = time
            lastDerivative = 0
            return value
        }
        var dt = time - prevTime
        if !(dt > 0) || dt > 0.5 { dt = 1.0 / 240.0 }
        let derivative = (value - prev) / dt
        let aD = alpha(cutoff: derivativeCutoff, dt: dt)
        let smoothedDerivative = aD * derivative + (1 - aD) * lastDerivative
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let a = alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * prev
        lastValue = result
        lastDerivative = smoothedDerivative
        lastTime = time
        return result
    }
}

/// Stabilizzatore 2D con un solo parametro "intensità" 0…1.
/// Lavora in coordinate normalizzate della superficie (0…1).
public struct PointStabilizer {
    public private(set) var strength: Double
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    public init(strength: Double = 0) {
        self.strength = min(max(strength, 0), 1)
        let (mc, b) = PointStabilizer.parameters(for: self.strength)
        fx = OneEuroFilter(minCutoff: mc, beta: b)
        fy = OneEuroFilter(minCutoff: mc, beta: b)
    }

    /// Mappa l'intensità sui parametri del filtro.
    /// 0 → disattivato; 1 → taglio 0,5 Hz a velocità nulla.
    static func parameters(for s: Double) -> (minCutoff: Double, beta: Double) {
        let minCutoff = 12.0 * (1 - s) + 0.5 * s
        let beta = 30.0 * (1 - s) + 4.0 * s
        return (minCutoff, beta)
    }

    public mutating func setStrength(_ s: Double) {
        let clamped = min(max(s, 0), 1)
        guard clamped != strength else { return }
        strength = clamped
        let (mc, b) = PointStabilizer.parameters(for: clamped)
        fx.minCutoff = mc; fx.beta = b
        fy.minCutoff = mc; fy.beta = b
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }

    public mutating func process(x: Double, y: Double, time: Double) -> (Double, Double) {
        guard strength > 0.001 else { return (x, y) }
        return (fx.filter(x, time: time), fy.filter(y, time: time))
    }
}
