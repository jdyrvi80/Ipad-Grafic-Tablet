//
//  CapabilityDetector.swift
//  iPad Graphic Tablet — iPad
//
//  Rileva le capacità REALI di iPad + Apple Pencil osservando gli eventi,
//  invece di dedurle dal modello: nessun dato simulato.
//   • pressione: variazione effettiva della forza durante i tratti
//     (Apple Pencil USB-C non ha sensore di pressione);
//   • hover / doppio tocco / squeeze / rotazione: attivati al primo evento ricevuto.
//  La pressione rilevata viene ricordata tra le sessioni, ma se per 3 tratti
//  consecutivi non varia viene ritirata (es. Pencil cambiata).
//

import Foundation

final class CapabilityDetector {
    private(set) var capabilities: DeviceCapabilities

    private var strokeMin: Float = .greatestFiniteMagnitude
    private var strokeMax: Float = 0
    private var strokeSamples = 0
    private var flatStrokes = 0
    private var rollMin: Float = .greatestFiniteMagnitude
    private var rollMax: Float = -.greatestFiniteMagnitude

    private static let storedKey = "detectedPressure"

    init() {
        var caps: DeviceCapabilities = [.multitouch, .osSupportsHover, .videoDisplay]
        if #available(iOS 17.5, *) { caps.insert(.osSupportsSqueeze) }
        if UserDefaults.standard.bool(forKey: CapabilityDetector.storedKey) { caps.insert(.pressure) }
        capabilities = caps
    }

    /// Osserva un campione a contatto. Restituisce true se le capacità sono cambiate.
    func observeContact(_ s: PenSample) -> Bool {
        var changed = false
        if !capabilities.contains(.tilt) {
            capabilities.insert(.tilt)
            changed = true
        }
        if s.flags.contains(.strokeBegan) {
            strokeMin = .greatestFiniteMagnitude
            strokeMax = 0
            strokeSamples = 0
        }
        if !s.flags.contains(.estimatedPressure) && s.flags.contains(.contact) {
            strokeMin = min(strokeMin, s.pressure)
            strokeMax = max(strokeMax, s.pressure)
            strokeSamples += 1
            if strokeMax - strokeMin > 0.05 && !capabilities.contains(.pressure) {
                capabilities.insert(.pressure)
                UserDefaults.standard.set(true, forKey: CapabilityDetector.storedKey)
                changed = true
            }
        }
        if s.roll != 0 {
            rollMin = min(rollMin, s.roll)
            rollMax = max(rollMax, s.roll)
            if rollMax - rollMin > 0.05 && !capabilities.contains(.roll) {
                capabilities.insert(.roll)
                changed = true
            }
        }
        if s.flags.contains(.strokeEnded) {
            // Tratto lungo con pressione costante: probabilmente nessun sensore.
            if strokeSamples > 30 && strokeMax - strokeMin < 0.005 {
                flatStrokes += 1
                if flatStrokes >= 3 && capabilities.contains(.pressure) {
                    capabilities.remove(.pressure)
                    UserDefaults.standard.set(false, forKey: CapabilityDetector.storedKey)
                    changed = true
                }
            } else if strokeSamples > 30 {
                flatStrokes = 0
            }
        }
        return changed
    }

    func observeHover() -> Bool { insert(.hover) }
    func observeDoubleTap() -> Bool { insert(.doubleTap) }
    func observeSqueeze() -> Bool { insert(.squeeze) }

    private func insert(_ c: DeviceCapabilities) -> Bool {
        guard !capabilities.contains(c) else { return false }
        capabilities.insert(c)
        return true
    }
}
