//
//  Calibration.swift
//  iPad Graphic Tablet — iPad
//
//  Correzione lineare per asse (scala + offset) calcolata con 4 bersagli.
//  La Apple Pencil è già molto precisa: la calibrazione serve a compensare
//  la parallasse percepita o pellicole sullo schermo. Valori limitati a
//  correzioni piccole per non poter rendere inutilizzabile la superficie.
//

import Foundation
import CoreGraphics

struct Calibration: Codable, Equatable {
    var scaleX: Double = 1
    var offsetX: Double = 0
    var scaleY: Double = 1
    var offsetY: Double = 0

    static let identity = Calibration()
    var isIdentity: Bool { self == .identity }

    /// Bersagli in coordinate normalizzate.
    static let targets: [CGPoint] = [
        CGPoint(x: 0.12, y: 0.15), CGPoint(x: 0.88, y: 0.15),
        CGPoint(x: 0.88, y: 0.85), CGPoint(x: 0.12, y: 0.85),
    ]

    /// Applica la correzione a un punto normalizzato.
    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        (min(max(x * scaleX + offsetX, 0), 1), min(max(y * scaleY + offsetY, 0), 1))
    }

    /// Regressione lineare per asse: atteso = scala · misurato + offset.
    static func fit(measured: [CGPoint], expected: [CGPoint]) -> Calibration? {
        guard measured.count == expected.count, measured.count >= 2 else { return nil }
        func solve(_ m: [Double], _ e: [Double]) -> (Double, Double)? {
            let n = Double(m.count)
            let mx = m.reduce(0, +) / n
            let ex = e.reduce(0, +) / n
            var num = 0.0, den = 0.0
            for i in 0..<m.count {
                num += (m[i] - mx) * (e[i] - ex)
                den += (m[i] - mx) * (m[i] - mx)
            }
            guard den > 1e-9 else { return nil }
            let a = num / den
            return (a, ex - a * mx)
        }
        guard let fx = solve(measured.map { Double($0.x) }, expected.map { Double($0.x) }),
              let fy = solve(measured.map { Double($0.y) }, expected.map { Double($0.y) }) else { return nil }
        let (ax, bx) = fx
        let (ay, by) = fy
        // Limiti di sicurezza: ±8% di scala, ±5% di spostamento.
        func clampScale(_ v: Double) -> Double { min(max(v, 0.92), 1.08) }
        func clampOffset(_ v: Double) -> Double { min(max(v, -0.05), 0.05) }
        return Calibration(scaleX: clampScale(ax), offsetX: clampOffset(bx),
                           scaleY: clampScale(ay), offsetY: clampOffset(by))
    }

    // MARK: Persistenza

    private static let key = "pencilCalibration"

    static func load() -> Calibration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(Calibration.self, from: data) else { return .identity }
        return c
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Calibration.key)
        }
    }
}
