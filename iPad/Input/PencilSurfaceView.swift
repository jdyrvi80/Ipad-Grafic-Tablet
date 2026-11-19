//
//  PencilSurfaceView.swift
//  iPad Graphic Tablet — iPad
//
//  Superficie nera che cattura la Apple Pencil con UIKit (non PencilKit:
//  PencilKit disegna, a noi servono i dati grezzi).
//
//  • tocchi della Pencil: touchesBegan/Moved/Ended + coalescedTouches (fino a 240 Hz)
//    con force, altitudeAngle, azimuthAngle, rollAngle (17.5+), preciseLocation;
//  • hover: UIHoverGestureRecognizer con zOffset/altitudine/azimut (iPad compatibili);
//  • doppio tocco e squeeze: UIPencilInteraction;
//  • dita (solo modalità Touchpad): gesture recognizer limitati ai tocchi diretti,
//    così non interferiscono mai con la Pencil.
//
//  Una vista nera continua a ricevere tutti gli eventi: lo schermo "nero" non
//  limita l'input. Ciò che iPadOS non consente è spegnere il pannello mantenendo
//  l'app attiva: per questo si usa nero puro (pixel spenti su OLED) + luminosità minima.
//

import UIKit

protocol PencilSurfaceDelegate: AnyObject {
    func surface(_ surface: PencilSurfaceView, didCapture samples: [PenSample])
    func surface(_ surface: PencilSurfaceView, didHover sample: PenSample)
    func surfaceHoverEnded(_ surface: PencilSurfaceView)
    func surface(_ surface: PencilSurfaceView, gesture: GestureMessage)
    func surface(_ surface: PencilSurfaceView, pencilGesture kind: PencilGestureKind, phase: GesturePhase)
    func surface(_ surface: PencilSurfaceView, didResize size: CGSize)
}

final class PencilSurfaceView: UIView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {

    weak var delegate: PencilSurfaceDelegate?

    /// Dito come puntatore (modalità Touchpad).
    var fingerPointerEnabled = false { didSet { updateFingerRecognizers() } }
    /// Modalità Display: un dito muove il cursore come un trackpad (tocco = clic, doppio tocco = doppio clic),
    /// tenere premuto non trascina; due dita zoom/spostamento dell'area.
    var displayFingers = false
    var palmRejection = true
    var calibration = Calibration.identity

    private var pencilTouch: UITouch?
    /// Fino a questo istante le dita sono ignorate (Pencil appena usata o in hover).
    private var pencilActiveUntil: TimeInterval = 0
    private var hoverEndWork: DispatchWorkItem?
    private var lastReportedSize: CGSize = .zero

    // Dita
    private var pan1: UIPanGestureRecognizer!
    private var pan2: UIPanGestureRecognizer!
    private var tap1: UITapGestureRecognizer!
    private var tap2: UITapGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var tap3: UITapGestureRecognizer!
    private var panMulti: UIPanGestureRecognizer!
    private var lastMultiTranslation: CGPoint = .zero
    private var lastMultiSpread: CGFloat = 0
    private var multiFingers = 0
    private var lastPinchScale: CGFloat = 1
    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint: CGPoint = .zero
    private var lastLongPressPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Trasparente: sotto può esserci lo schermo del Mac (modalità Display).
        // Il nero di fondo è quello della vista radice.
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        setupFingerRecognizers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastReportedSize && bounds.width > 0 && bounds.height > 0 {
            lastReportedSize = bounds.size
            delegate?.surface(self, didResize: bounds.size)
        }
    }

    // MARK: - Apple Pencil: contatto

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .pencil {
            pencilTouch = t
            hoverEndWork?.cancel()
            emit(t, event: event, phase: .began)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .pencil && t === pencilTouch {
            emit(t, event: event, phase: .moved)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .pencil && t === pencilTouch {
            emit(t, event: event, phase: .ended)
            pencilTouch = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .pencil && t === pencilTouch {
            emit(t, event: event, phase: .cancelled)
            pencilTouch = nil
        }
    }

    private func emit(_ touch: UITouch, event: UIEvent?, phase: UITouch.Phase) {
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        var samples: [PenSample] = []
        samples.reserveCapacity(coalesced.count)
        for (i, t) in coalesced.enumerated() {
            let isFirst = i == 0
            let isLast = i == coalesced.count - 1
            var flags: PenFlags = [.contact]
            if phase == .began && isFirst { flags.insert(.strokeBegan) }
            if isLast && phase == .ended { flags = [.strokeEnded] }
            if isLast && phase == .cancelled { flags = [.strokeEnded, .cancelled] }
            if t.estimatedPropertiesExpectingUpdates.contains(.force) { flags.insert(.estimatedPressure) }
            samples.append(makeSample(from: t, flags: flags))
        }
        pencilActiveUntil = ProcessInfo.processInfo.systemUptime + 0.6
        delegate?.surface(self, didCapture: samples)
    }

    private func makeSample(from t: UITouch, flags: PenFlags) -> PenSample {
        let loc = t.preciseLocation(in: self)
        let (x, y) = normalized(loc)
        let maxForce = t.maximumPossibleForce
        let pressure = maxForce > 0 ? Float(min(max(t.force / maxForce, 0), 1)) : 0
        var roll: Float = 0
        if #available(iOS 17.5, *) { roll = Float(t.rollAngle) }
        return PenSample(timestamp: t.timestamp, x: Float(x), y: Float(y),
                         pressure: pressure,
                         altitude: Float(t.altitudeAngle),
                         azimuth: Float(t.azimuthAngle(in: self)),
                         roll: roll, hoverDistance: 0, flags: flags)
    }

    private func normalized(_ p: CGPoint) -> (Double, Double) {
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        return calibration.apply(Double(p.x / w), Double(p.y / h))
    }

    // MARK: - Apple Pencil: hover

    @objc private func handleHover(_ r: UIHoverGestureRecognizer) {
        // zOffset > 0 solo per la Pencil in hover (il puntatore del trackpad ha zOffset 0).
        switch r.state {
        case .began, .changed:
            guard r.zOffset > 0, pencilTouch == nil else { return }
            hoverEndWork?.cancel()
            let (x, y) = normalized(r.location(in: self))
            var roll: Float = 0
            if #available(iOS 17.5, *) { roll = Float(r.rollAngle) }
            let sample = PenSample(timestamp: ProcessInfo.processInfo.systemUptime,
                                   x: Float(x), y: Float(y), pressure: 0,
                                   altitude: Float(r.altitudeAngle),
                                   azimuth: Float(r.azimuthAngle(in: self)),
                                   roll: roll, hoverDistance: Float(r.zOffset), flags: [.hovering])
            pencilActiveUntil = ProcessInfo.processInfo.systemUptime + 0.6
            delegate?.surface(self, didHover: sample)
        case .ended, .cancelled:
            // L'hover termina anche quando la punta tocca lo schermo: si attende un attimo
            // per distinguere "contatto" da "penna allontanata".
            hoverEndWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pencilTouch == nil else { return }
                self.delegate?.surfaceHoverEnded(self)
            }
            hoverEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        default:
            break
        }
    }

    // MARK: - Apple Pencil: doppio tocco e squeeze

    /// iPadOS < 17.5
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        delegate?.surface(self, pencilGesture: .doubleTap, phase: .ended)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        delegate?.surface(self, pencilGesture: .doubleTap, phase: .ended)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        let phase: GesturePhase
        switch squeeze.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        @unknown default: phase = .ended
        }
        delegate?.surface(self, pencilGesture: .squeeze, phase: phase)
    }

    // MARK: - Dita (modalità Touchpad)

    private func setupFingerRecognizers() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 8

        pan1 = UIPanGestureRecognizer(target: self, action: #selector(handlePan1(_:)))
        pan1.minimumNumberOfTouches = 1
        pan1.maximumNumberOfTouches = 1
        pan1.require(toFail: longPress)

        pan2 = UIPanGestureRecognizer(target: self, action: #selector(handlePan2(_:)))
        pan2.minimumNumberOfTouches = 2
        pan2.maximumNumberOfTouches = 2

        tap1 = UITapGestureRecognizer(target: self, action: #selector(handleTap1(_:)))
        tap2 = UITapGestureRecognizer(target: self, action: #selector(handleTap2(_:)))
        tap2.numberOfTouchesRequired = 2

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        // Tre o più dita: tocco (Ricerca) e gesti di sistema (Mission Control, Spaces, Launchpad…).
        tap3 = UITapGestureRecognizer(target: self, action: #selector(handleTap3(_:)))
        tap3.numberOfTouchesRequired = 3
        panMulti = UIPanGestureRecognizer(target: self, action: #selector(handlePanMulti(_:)))
        panMulti.minimumNumberOfTouches = 3
        panMulti.maximumNumberOfTouches = 5

        for r in [longPress, pan1, pan2, tap1, tap2, pinch, tap3, panMulti] as [UIGestureRecognizer] {
            r.allowedTouchTypes = direct
            r.delegate = self
            r.cancelsTouchesInView = false
            addGestureRecognizer(r)
        }
        updateFingerRecognizers()
    }

    private func updateFingerRecognizers() {
        for r in [longPress, pan1, pan2, tap1, tap2, pinch, tap3, panMulti] as [UIGestureRecognizer?] {
            r?.isEnabled = fingerPointerEnabled
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        fingerAccepted(touch)
    }

    private func fingerAccepted(_ touch: UITouch) -> Bool {
        guard fingerPointerEnabled, touch.type == .direct else { return false }
        if palmRejection {
            // Pencil attiva o appena sollevata: le dita sono quasi certamente il palmo.
            if ProcessInfo.processInfo.systemUptime < pencilActiveUntil || pencilTouch != nil { return false }
            // Contatto molto ampio = palmo.
            if touch.majorRadius > 32 { return false }
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Scorrimento e pinch a due dita insieme.
        (g === pan2 && other === pinch) || (g === pinch && other === pan2)
    }

    @objc private func handlePan1(_ r: UIPanGestureRecognizer) {
        guard r.state == .changed else { return }
        let t = r.translation(in: self)
        r.setTranslation(.zero, in: self)
        delegate?.surface(self, gesture: GestureMessage(kind: .pointerMove, dx: Float(t.x), dy: Float(t.y)))
    }

    @objc private func handlePan2(_ r: UIPanGestureRecognizer) {
        switch r.state {
        case .changed:
            let t = r.translation(in: self)
            r.setTranslation(.zero, in: self)
            delegate?.surface(self, gesture: GestureMessage(kind: .scroll, dx: Float(t.x), dy: Float(t.y), fingers: 2))
        case .ended, .cancelled:
            delegate?.surface(self, gesture: GestureMessage(kind: .gestureEnd, fingers: 2))
        default: break
        }
    }

    /// Posizione normalizzata (0…1) sulla superficie.
    private func normalized(_ p: CGPoint) -> (Float, Float) {
        guard bounds.width > 0, bounds.height > 0 else { return (0.5, 0.5) }
        let u = Float(min(max(p.x / bounds.width, 0), 1))
        let v = Float(min(max(p.y / bounds.height, 0), 1))
        return (u, v)
    }

    @objc private func handleTap1(_ r: UITapGestureRecognizer) {
        let now = ProcessInfo.processInfo.systemUptime
        let p = r.location(in: self)
        let isDouble = now - lastTapTime < 0.45 && hypot(p.x - lastTapPoint.x, p.y - lastTapPoint.y) < 40
        if displayFingers {
            // Modalità Display: clic nel punto toccato (doppio clic nel punto del primo tocco).
            let (u, v) = normalized(isDouble ? lastTapPoint : p)
            delegate?.surface(self, gesture: GestureMessage(kind: isDouble ? .doubleTapAt : .tapAt, dx: u, dy: v))
        } else {
            // Trackpad: la posizione del tocco serve per il clic secondario negli angoli.
            let (u, v) = normalized(p)
            let kind: GestureKind = isDouble ? .doubleClick : .leftClick
            delegate?.surface(self, gesture: GestureMessage(kind: kind, dx: isDouble ? 0 : u, dy: isDouble ? 0 : v))
        }
        lastTapTime = isDouble ? 0 : now
        lastTapPoint = p
    }

    @objc private func handleTap3(_ r: UITapGestureRecognizer) {
        delegate?.surface(self, gesture: GestureMessage(kind: .threeFingerTap, fingers: 3))
        delegate?.surface(self, gesture: GestureMessage(kind: .multiEnd, fingers: 3))
    }

    /// Distanza media delle dita dal loro centro (per il pizzico con pollice e tre dita).
    private func spread(of r: UIGestureRecognizer) -> CGFloat {
        let n = r.numberOfTouches
        guard n > 0 else { return 0 }
        let c = r.location(in: self)
        var total: CGFloat = 0
        for i in 0..<n {
            let p = r.location(ofTouch: i, in: self)
            total += hypot(p.x - c.x, p.y - c.y)
        }
        return total / CGFloat(n)
    }

    @objc private func handlePanMulti(_ r: UIPanGestureRecognizer) {
        let fingers = UInt8(clamping: r.numberOfTouches)
        switch r.state {
        case .began:
            lastMultiTranslation = .zero
            lastMultiSpread = spread(of: r)
            multiFingers = Int(fingers)
        case .changed:
            let t = r.translation(in: self)
            let dx = Float(t.x - lastMultiTranslation.x)
            let dy = Float(t.y - lastMultiTranslation.y)
            lastMultiTranslation = t
            let n = UInt8(clamping: max(multiFingers, Int(fingers)))
            delegate?.surface(self, gesture: GestureMessage(kind: .multiMove, dx: dx, dy: dy, fingers: n))
            let s = spread(of: r)
            if n >= 4, lastMultiSpread > 0, s > 0 {
                let ratio = s / lastMultiSpread
                if abs(ratio - 1) > 0.02 {
                    delegate?.surface(self, gesture: GestureMessage(kind: .multiPinch, scale: Float(ratio), fingers: n))
                    lastMultiSpread = s
                }
            }
        case .ended, .cancelled, .failed:
            let n = UInt8(clamping: max(multiFingers, 3))
            delegate?.surface(self, gesture: GestureMessage(kind: .multiEnd, fingers: n))
            multiFingers = 0
        default:
            break
        }
    }

    @objc private func handleTap2(_ r: UITapGestureRecognizer) {
        if displayFingers {
            let (u, v) = normalized(r.location(in: self))   // centro delle due dita
            delegate?.surface(self, gesture: GestureMessage(kind: .rightTapAt, dx: u, dy: v, fingers: 2))
        } else {
            delegate?.surface(self, gesture: GestureMessage(kind: .rightClick, fingers: 2))
        }
    }

    @objc private func handleLongPress(_ r: UILongPressGestureRecognizer) {
        let p = r.location(in: self)
        if displayFingers {
            // Dito fermo e poi mosso: solo movimento del cursore, nessun trascinamento.
            switch r.state {
            case .began:
                lastLongPressPoint = p
            case .changed:
                let d = CGPoint(x: p.x - lastLongPressPoint.x, y: p.y - lastLongPressPoint.y)
                lastLongPressPoint = p
                delegate?.surface(self, gesture: GestureMessage(kind: .pointerMove, dx: Float(d.x), dy: Float(d.y)))
            default:
                break
            }
            return
        }
        switch r.state {
        case .began:
            lastLongPressPoint = p
            delegate?.surface(self, gesture: GestureMessage(kind: .dragBegin))
        case .changed:
            let d = CGPoint(x: p.x - lastLongPressPoint.x, y: p.y - lastLongPressPoint.y)
            lastLongPressPoint = p
            delegate?.surface(self, gesture: GestureMessage(kind: .dragMove, dx: Float(d.x), dy: Float(d.y)))
        case .ended, .cancelled, .failed:
            delegate?.surface(self, gesture: GestureMessage(kind: .dragEnd))
        default: break
        }
    }

    @objc private func handlePinch(_ r: UIPinchGestureRecognizer) {
        switch r.state {
        case .began:
            lastPinchScale = 1
        case .changed:
            let relative = r.scale / max(lastPinchScale, 0.001)
            lastPinchScale = r.scale
            // Centro delle dita (normalizzato): in modalità Display è il punto fisso dello zoom.
            let c = r.location(in: self)
            let u = Float(bounds.width > 0 ? min(max(c.x / bounds.width, 0), 1) : 0.5)
            let v = Float(bounds.height > 0 ? min(max(c.y / bounds.height, 0), 1) : 0.5)
            delegate?.surface(self, gesture: GestureMessage(kind: .pinch, dx: u, dy: v, scale: Float(relative), fingers: 2))
        case .ended, .cancelled:
            delegate?.surface(self, gesture: GestureMessage(kind: .gestureEnd, fingers: 2))
        default: break
        }
    }
}
