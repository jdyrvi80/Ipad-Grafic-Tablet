//
//  CoordinateMapper.swift
//  iPad Graphic Tablet — Mac
//
//  Converte le coordinate normalizzate dell'iPad in coordinate dello schermo Mac:
//  rotazione (0/90/180/270°, mancini = +180°), area attiva, rapporto
//  d'aspetto e monitor di destinazione.
//

import Foundation
import CoreGraphics

struct CoordinateMapper {
    /// Quarti di giro effettivi (rotazione + mancino).
    private(set) var turns = 0
    /// Dimensione della superficie iPad in punti, DOPO la rotazione.
    private(set) var rotatedSize = CGSize(width: 1024, height: 768)
    /// Area di input nello spazio ruotato (normalizzata).
    private(set) var inputRect = NormRect.full
    /// Monitor di destinazione (spazio globale Quartz).
    private(set) var target = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    var rotatedAspect: Double {
        rotatedSize.height > 0 ? Double(rotatedSize.width / rotatedSize.height) : 4.0 / 3.0
    }

    mutating func configure(profile: TabletProfile, display: DisplayInfo?, surface: CGSize) {
        let w = max(surface.width, 1)
        let h = max(surface.height, 1)
        if profile.mode == .display {
            // Modalità Display: l'iPad mostra l'area scelta del monitor, senza rotazioni,
            // adattata (letterbox) alle proporzioni dell'iPad. La penna punta esattamente
            // sul pixel che vede sotto la punta.
            turns = 0
            rotatedSize = CGSize(width: w, height: h)
            if let display {
                target = DisplayRegion.globalRect(profile.displayRegion.clamped(), in: display.bounds)
            }
            let regionAspect: Double = target.height > 0 ? Double(target.width / target.height) : 16.0 / 9.0
            inputRect = InputArea.effectiveRect(activeArea: .full, rotatedAspect: rotatedAspect,
                                                targetAspect: regionAspect)
            return
        }
        turns = profile.effectiveQuarterTurns
        rotatedSize = turns % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        if let display { target = display.bounds }
        let constrain = profile.keepAspectRatio && profile.penMapping == .absolute
        inputRect = InputArea.effectiveRect(activeArea: profile.activeArea,
                                            rotatedAspect: rotatedAspect,
                                            targetAspect: constrain ? (display?.aspect ?? 16.0 / 9.0) : nil)
    }

    /// Coordinate iPad (non ruotate) → spazio ruotato.
    func rotate(_ x: Double, _ y: Double) -> (Double, Double) {
        QuarterTurn.rotatePoint(x, y, turns: turns)
    }

    /// Spazio ruotato → punto assoluto sul monitor di destinazione.
    func absolutePoint(u: Double, v: Double) -> CGPoint {
        let r = inputRect
        let s = min(max((u - Double(r.x)) / Double(max(r.width, 0.0001)), 0), 1)
        let t = min(max((v - Double(r.y)) / Double(max(r.height, 0.0001)), 0), 1)
        return CGPoint(x: target.minX + CGFloat(s) * (target.width - 1),
                       y: target.minY + CGFloat(t) * (target.height - 1))
    }

    /// Spostamento nello spazio ruotato → punti iPad.
    func physicalDelta(du: Double, dv: Double) -> CGPoint {
        CGPoint(x: CGFloat(du) * rotatedSize.width, y: CGFloat(dv) * rotatedSize.height)
    }

    /// Ruota un vettore direzione (inclinazione) come la superficie.
    func rotateVector(_ dx: Double, _ dy: Double) -> (Double, Double) {
        QuarterTurn.rotateVector(dx, dy, turns: turns)
    }

    /// Area di input espressa nelle coordinate NON ruotate dell'iPad (da disegnare sull'iPad).
    var unrotatedInputRect: NormRect {
        InputArea.unrotated(inputRect, turns: turns)
    }
}
