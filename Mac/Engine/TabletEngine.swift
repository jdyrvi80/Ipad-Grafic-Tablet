//
//  TabletEngine.swift
//  iPad Graphic Tablet — Mac
//
//  Il cuore dell'app Mac: trasforma i campioni della Apple Pencil in eventi
//  tavoletta macOS.
//
//  Pipeline per ogni campione (tutto sulla coda "tablet.core", nessun lock):
//    stabilizzazione → rotazione → mapping assoluto/relativo/precisione →
//    curva di pressione → inclinazione → macchina a stati della penna
//    (prossimità, punta giù, trascinamento, punta su) → CGEvent.
//

import Foundation
import CoreGraphics

/// Statistiche per la dashboard (pubblicate ~10 volte al secondo).
struct EngineStats: Equatable {
    var sampleRate: Double = 0
    var rawPressure: Float = 0
    var outputPressure: Double = 0
    var tiltX: Double = 0
    var tiltY: Double = 0
    var rollDegrees: Double = 0
    var inProximity = false
    var tipDown = false
    var cursor = CGPoint.zero
    /// Latenza stimata penna → evento sul Mac (richiede la stima dell'offset degli orologi).
    var penLatencyMs: Double?
    var sequenceGaps = 0
    var eventsPosted = 0
    /// Gesti delle dita ricevuti dall'iPad (diagnostica).
    var fingerGestures = 0
    var canPostEvents = false
    var cursorLocked = false
    var precisionMode = false
    var eraserActive = false
}

/// Richieste che il motore inoltra all'app (sul main thread).
enum EngineRequest {
    case nextProfile
    case stateChanged          // blocco cursore / precisione / gomma cambiati
    case needsPermission
}

final class TabletEngine {

    private var queue = DispatchQueue(label: "tablet.core.placeholder")
    private let backend: InputBackend
    private let keys = KeyboardLayoutResolver.shared

    // Configurazione
    private var profile = ProfilePresets.generic
    private var displays: [DisplayInfo] = []
    private var targetDisplay: DisplayInfo?
    private var mapper = CoordinateMapper()
    private var stabilizer = PointStabilizer()

    // Stato di sessione
    private(set) var cursorLocked = false
    private(set) var precisionMode = false
    private(set) var eraserActive = false
    private var canPostEvents = false
    private var rttMs: Double = 0
    private var clockOffset: Double?
    private var mirrorStatus = ""

    // Dispositivo
    private var connected = false
    private var capabilities: DeviceCapabilities = []
    private var surface = CGSize(width: 1024, height: 768)
    private var screenScale: Double = 2

    // Stato penna
    private var inProximity = false
    private var proximityPointer: PointerKind = .pen
    private var tipDown = false
    private var lastCursor: CGPoint?
    private var lastUV: (Double, Double)?
    private var lastAbsolute: CGPoint?
    private var proximityTimer: DispatchSourceTimer?
    private var lastSequence: UInt32?
    /// Le capacità sono cambiate: la prossimità va riannunciata con la nuova maschera.
    private var pendingReannounce = false

    // Tastiera
    private var heldKeys: [String: (code: CGKeyCode, flags: CGEventFlags)] = [:]
    private var heldFlags: CGEventFlags = []

    // Trackpad
    private var touchDragging = false
    private var pinchAccumulator: Double = 1
    private var scrolling = false
    private var scrollVX: Double = 0
    private var scrollVY: Double = 0
    private var lastScrollTime: Double = 0
    private var momentumTimer: DispatchSourceTimer?
    private var momentumStarted = false
    private var multiFingers = 0
    private var multiAccumX: Double = 0
    private var multiAccumY: Double = 0
    private var multiFired = false
    private var multiDragging = false
    private var multiPinchScale: Double = 1

    // Modalità Display: zoom e spostamento dell'area a due dita
    private var lastRegionConfigSend: Double = 0
    private var regionConfigScheduled = false
    private var regionReportScheduled = false

    // Statistiche
    private var rate = RateMeter()
    private var stats = EngineStats()
    private var statsTimer: DispatchSourceTimer?
    private var permissionCheckCounter = 0

    var onStats: ((EngineStats) -> Void)?
    var onRequest: ((EngineRequest) -> Void)?
    /// Configurazione da reinviare SUBITO all'iPad (chiamato sulla coda di rete).
    var onSessionConfigChanged: (() -> Void)?
    /// L'area mostrata è cambiata dall'iPad (zoom/spostamento): id del profilo e nuova area, sul main thread.
    var onDisplayRegionChanged: ((UUID, NormRect) -> Void)?

    var backendName: String { backend.name }

    init(backend: InputBackend = CGEventTabletBackend()) {
        self.backend = backend
    }

    /// Collega il motore alla coda di rete (chiamato dal ConnectionManager).
    func attach(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: TabletEngine.queueKey, value: true)
        canPostEvents = PermissionManager.canPostEvents
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.1, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.publishStats() }
        statsTimer = t
        t.resume()
    }

    // MARK: - Configurazione (chiamabile dal main thread)

    func apply(profile: TabletProfile, displays: [DisplayInfo]) {
        queue.async {
            let modeChanged = profile.mode != self.profile.mode || profile.penMapping != self.profile.penMapping
            self.profile = profile
            self.displays = displays
            self.targetDisplay = DisplayManager.resolve(uuid: profile.displayUUID, in: displays)
            self.stabilizer.setStrength(profile.stabilization)
            self.reconfigureMapper()
            if modeChanged {
                // Cambio di modalità: si riparte puliti per evitare salti o click bloccati.
                self.releaseEverything()
            }
        }
    }

    func setCursorLocked(_ locked: Bool) {
        queue.async {
            guard self.cursorLocked != locked else { return }
            self.cursorLocked = locked
            if locked { self.releasePen() }
            tlog.info(locked ? "Cursore bloccato" : "Cursore sbloccato")
        }
    }

    func setPrecisionMode(_ on: Bool) {
        queue.async {
            self.precisionMode = on
            self.lastAbsolute = nil
            tlog.info(on ? "Modalità precisione attiva" : "Modalità precisione disattivata")
        }
    }

    func toggleEraser() {
        dispatchIfNeeded {
            self.eraserActive.toggle()
            // Una Wacom che si gira esce e rientra in prossimità come "eraser".
            if self.inProximity { self.exitProximity() }
            tlog.info(self.eraserActive ? "Puntatore: gomma" : "Puntatore: penna")
            self.notify(.stateChanged)
        }
    }

    func updateLatency(_ avgMs: Double) {
        rttMs = avgMs   // già sulla coda
    }

    func updateClockOffset(_ offset: Double?) {
        clockOffset = offset
    }

    /// Messaggio sullo stato della trasmissione schermo da mostrare sull'iPad.
    func setMirrorStatus(_ message: String) {
        queue.async { self.mirrorStatus = message }
    }

    func refreshPermission() {
        queue.async { self.canPostEvents = PermissionManager.canPostEvents }
    }

    private func dispatchIfNeeded(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: TabletEngine.queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }
    private static let queueKey = DispatchSpecificKey<Bool>()

    private func reconfigureMapper() {
        mapper.configure(profile: profile, display: targetDisplay, surface: surface)
        lastUV = nil
        lastAbsolute = nil
    }

    // MARK: - Dispositivo

    func deviceConnected(hello: HelloMessage, link: LinkKind) {
        connected = true
        capabilities = hello.capabilities
        surface = CGSize(width: CGFloat(hello.surfaceWidth), height: CGFloat(hello.surfaceHeight))
        screenScale = Double(hello.screenScale)
        lastSequence = nil
        stats = EngineStats()
        reconfigureMapper()
        canPostEvents = PermissionManager.canPostEvents
        if !canPostEvents { notify(.needsPermission) }
        tlog.info("Motore: iPad \(Int(surface.width))×\(Int(surface.height)) pt, capacità: \(capabilities.descriptionIT.joined(separator: ", "))")
    }

    func updateDevice(capabilities: DeviceCapabilities, surface: CGSize) {
        let surfaceChanged = surface != self.surface
        if capabilities != self.capabilities {
            pendingReannounce = true
            tlog.info("Capacità aggiornate: \(capabilities.descriptionIT.joined(separator: ", "))")
        }
        self.capabilities = capabilities
        self.surface = surface
        if surfaceChanged { reconfigureMapper() }
    }

    func deviceDisconnected() {
        releaseEverything()
        connected = false
        clockOffset = nil
    }

    /// Rilascia punta, tasti tenuti e trascinamenti: nessun tasto "incastrato".
    private func releaseEverything() {
        releasePen()
        stopMomentum()
        if scrolling {
            scrolling = false
            backend.scroll(dx: 0, dy: 0, flags: [], phase: .ended)
        }
        multiDragging = false
        multiFingers = 0
        multiFired = false
        if touchDragging {
            backend.mouseButton(.left, down: false, at: backend.cursorLocation, clickCount: 1, flags: [])
            touchDragging = false
        }
        for (_, held) in heldKeys {
            backend.key(code: held.code, down: false, flags: [])
        }
        heldKeys.removeAll()
        heldFlags = []
        pinchAccumulator = 1
    }

    private func releasePen() {
        if tipDown {
            let p = lastCursor ?? backend.cursorLocation
            backend.pen(.up, PenEventData(location: p, pressure: 0, tiltX: 0, tiltY: 0, rotationDegrees: 0,
                                          tabletX: 0, tabletY: 0, deltaX: 0, deltaY: 0), flags: heldFlags)
            tipDown = false
        }
        if inProximity { exitProximity() }
    }

    // MARK: - Penna

    func handlePen(_ samples: [PenSample]) {
        guard connected else { return }
        let now = MonotonicClock.now()
        rate.tick(now, count: samples.count)
        for s in samples {
            if s.flags.contains(.predicted) { continue }
            if let last = lastSequence, s.sequence > last &+ 1 {
                stats.sequenceGaps += Int(s.sequence - last - 1)
            }
            lastSequence = s.sequence
            process(s)
        }
        if let last = samples.last, let offset = clockOffset {
            // Istante del campione sull'orologio del Mac → età al momento dell'invio dell'evento.
            let age = (now - (last.timestamp - offset)) * 1000
            if age > -5 && age < 1000 { stats.penLatencyMs = max(age, 0) }
        }
    }

    private func process(_ s: PenSample) {
        // Uscita esplicita dal raggio di hover.
        if s.flags.contains(.proximityOut) {
            exitProximity()
            return
        }
        guard !cursorLocked else {
            if tipDown || inProximity { releasePen() }
            return
        }
        if pendingReannounce && inProximity && !tipDown {
            // Uscita e rientro: le app rileggono la maschera (es. pressione appena rilevata).
            exitProximity()
            pendingReannounce = false
        }

        let hasPressure = capabilities.contains(.pressure)
        let curve = profile.pressureCurve
        let ended = s.flags.contains(.strokeEnded) || s.flags.contains(.cancelled)
        let contact = s.flags.contains(.contact) && !ended
        let tipShouldBeDown = contact && (!hasPressure || curve.tipThreshold <= 0 || curve.isTipDown(s.pressure))

        // Su iPad senza hover ogni tratto è un nuovo ingresso: niente salti in modalità relativa.
        if s.flags.contains(.strokeBegan) {
            stabilizer.reset()
            if !capabilities.contains(.hover) { lastUV = nil; lastAbsolute = nil }
        }
        if !inProximity { stabilizer.reset() }

        let (sx, sy) = stabilizer.process(x: Double(s.x), y: Double(s.y), time: s.timestamp)
        let (u, v) = mapper.rotate(sx, sy)

        // Posizione del cursore.
        let previous = lastCursor ?? backend.cursorLocation
        var point: CGPoint
        // In modalità Display la penna è sempre assoluta: deve coincidere con l'immagine.
        if profile.penMapping == .relative && profile.mode != .display {
            if let last = lastUV {
                let d = mapper.physicalDelta(du: u - last.0, dv: v - last.1)
                let k = profile.cursorSpeed * (precisionMode ? profile.precisionFactor : 1)
                point = CGPoint(x: previous.x + d.x * CGFloat(k), y: previous.y + d.y * CGFloat(k))
            } else {
                point = previous
            }
        } else {
            let absPoint = mapper.absolutePoint(u: u, v: v)
            if precisionMode, let lastAbs = lastAbsolute {
                // Precisione in assoluto: si muove di una frazione dello spostamento reale.
                let k = CGFloat(profile.precisionFactor)
                point = CGPoint(x: previous.x + (absPoint.x - lastAbs.x) * k,
                                y: previous.y + (absPoint.y - lastAbs.y) * k)
            } else {
                point = absPoint
            }
            lastAbsolute = absPoint
        }
        point = DisplayManager.clamp(point, to: displays, preferring: targetDisplay)
        lastUV = (u, v)

        // Inclinazione: vettore dall'azimut, ampiezza dall'altitudine (0 = penna verticale).
        var tiltX = 0.0, tiltY = 0.0
        if profile.sendTilt && capabilities.contains(.tilt) {
            let magnitude = min(max((Double.pi / 2 - Double(s.altitude)) / (Double.pi / 2), 0), 1)
            let (vx, vy) = mapper.rotateVector(cos(Double(s.azimuth)), sin(Double(s.azimuth)))
            tiltX = vx * magnitude
            tiltY = vy * magnitude
        }
        let rollDeg = capabilities.contains(.roll) ? Double(s.roll) * 180 / .pi : 0

        let pressureOut: Double
        if tipShouldBeDown {
            pressureOut = hasPressure ? Double(curve.contactPressure(s.pressure)) : 1.0
        } else {
            pressureOut = 0
        }

        let data = PenEventData(
            location: point,
            pressure: pressureOut,
            tiltX: tiltX, tiltY: tiltY,
            rotationDegrees: rollDeg,
            tabletX: Int64(u * Double(mapper.rotatedSize.width) * screenScale),
            tabletY: Int64(v * Double(mapper.rotatedSize.height) * screenScale),
            deltaX: Double(point.x - previous.x),
            deltaY: Double(point.y - previous.y))

        if !inProximity { enterProximity() }

        if tipShouldBeDown {
            backend.pen(tipDown ? .drag : .down, data, flags: heldFlags)
            tipDown = true
            lastCursor = point
        } else if tipDown {
            backend.pen(.up, data, flags: heldFlags)
            tipDown = false
            lastCursor = point
        } else if !s.flags.contains(.hovering) || profile.hoverMovesCursor {
            // Hover, oppure contatto sotto la soglia di click: solo spostamento.
            backend.pen(.hover, data, flags: heldFlags)
            lastCursor = point
        }
        stats.eventsPosted &+= 1

        // Statistiche
        stats.rawPressure = s.pressure
        stats.outputPressure = pressureOut
        stats.tiltX = tiltX
        stats.tiltY = tiltY
        stats.rollDegrees = rollDeg
        stats.cursor = point

        armProximityTimer(strokeEnded: ended && !capabilities.contains(.hover))
    }

    private func enterProximity() {
        pendingReannounce = false   // l'ingresso usa già la maschera aggiornata
        proximityPointer = eraserActive ? .eraser : .pen
        backend.proximity(entering: true, pointer: proximityPointer, capabilities: capabilities)
        inProximity = true
    }

    private func exitProximity() {
        proximityTimer?.cancel()
        proximityTimer = nil
        if tipDown {
            let p = lastCursor ?? backend.cursorLocation
            backend.pen(.up, PenEventData(location: p, pressure: 0, tiltX: 0, tiltY: 0, rotationDegrees: 0,
                                          tabletX: 0, tabletY: 0, deltaX: 0, deltaY: 0), flags: heldFlags)
            tipDown = false
        }
        if inProximity {
            backend.proximity(entering: false, pointer: proximityPointer, capabilities: capabilities)
            inProximity = false
        }
        lastUV = nil
        lastAbsolute = nil
        // Al rientro si riparte dalla posizione REALE del cursore (l'utente potrebbe aver usato il mouse).
        lastCursor = nil
        stabilizer.reset()
    }

    /// Timer di sicurezza: se non arrivano campioni la penna esce dalla prossimità.
    /// • senza hover: uscita subito dopo la fine del tratto;
    /// • punta giù: attesa lunga (una punta ferma può non generare eventi; la fine del
    ///   tratto arriva comunque esplicitamente e la disconnessione rilascia tutto);
    /// • hover fermo: l'iPad invia l'uscita esplicita, il timer è solo una rete di sicurezza.
    private func armProximityTimer(strokeEnded: Bool) {
        proximityTimer?.cancel()
        let delay: Double
        if strokeEnded { delay = 0.25 }
        else if tipDown { delay = 8.0 }
        else { delay = capabilities.contains(.hover) ? 3.0 : 1.0 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in self?.exitProximity() }
        proximityTimer = t
        t.resume()
    }

    // MARK: - Pulsanti e gesti della Pencil

    func handleButton(_ b: ButtonMessage) {
        guard let button = profile.button(id: b.buttonID) else { return }
        perform(button.action, pressed: b.pressed, holdKey: "btn-\(b.buttonID)")
    }

    func handlePencilGesture(_ g: PencilGestureMessage) {
        let action = g.kind == .doubleTap ? profile.doubleTapAction : profile.squeezeAction
        let key = g.kind == .doubleTap ? "pencil-tap" : "pencil-squeeze"
        if action.isHold {
            switch g.phase {
            case .began: perform(action, pressed: true, holdKey: key)
            case .ended, .cancelled: perform(action, pressed: false, holdKey: key)
            case .changed: break
            }
        } else if g.phase == .ended {
            perform(action, pressed: true, holdKey: key)
            perform(action, pressed: false, holdKey: key)
        }
    }

    private func perform(_ action: ButtonAction, pressed: Bool, holdKey: String) {
        switch action {
        case .shortcut(let combo):
            if pressed { tap(combo) }
        case .holdKey(let combo):
            if pressed { holdDown(combo, key: holdKey) } else { holdUp(key: holdKey) }
        case .toggleCursorLock:
            guard pressed else { return }
            cursorLocked.toggle()
            if cursorLocked { releasePen() }
            notify(.stateChanged)
        case .togglePrecision:
            guard pressed else { return }
            precisionMode.toggle()
            lastAbsolute = nil
            notify(.stateChanged)
        case .toggleEraser:
            if pressed { toggleEraser() }
        case .nextProfile:
            if pressed { notify(.nextProfile) }
        case .nextMode:
            break   // azione di versioni precedenti: c'è una sola modalità
        case .none:
            break
        }
    }

    /// Codici dei tasti modificatori da premere per una combinazione.
    private func modifierKeys(for flags: CGEventFlags) -> [(CGKeyCode, CGEventFlags)] {
        var out: [(CGKeyCode, CGEventFlags)] = []
        if flags.contains(.maskControl) { out.append((CGKeyCode(MacKeyCode.control), .maskControl)) }
        if flags.contains(.maskAlternate) { out.append((CGKeyCode(MacKeyCode.option), .maskAlternate)) }
        if flags.contains(.maskShift) { out.append((CGKeyCode(MacKeyCode.shift), .maskShift)) }
        if flags.contains(.maskCommand) { out.append((CGKeyCode(MacKeyCode.command), .maskCommand)) }
        return out
    }

    /// Pressione e rilascio completi, modificatori inclusi (come una tastiera reale).
    private func tap(_ combo: KeyCombo) {
        guard let resolved = keys.resolve(combo) else {
            tlog.warn("Scorciatoia non risolvibile sul layout corrente: \(combo.displayName)")
            return
        }
        let code = resolved.code
        let comboFlags = resolved.flags
        let extra = comboFlags.subtracting(heldFlags)
        var flags = heldFlags
        let mods = modifierKeys(for: extra)
        for (modCode, modFlag) in mods {
            flags.insert(modFlag)
            backend.key(code: modCode, down: true, flags: flags)
        }
        backend.key(code: code, down: true, flags: flags)
        backend.key(code: code, down: false, flags: flags)
        for (modCode, modFlag) in mods.reversed() {
            flags.remove(modFlag)
            backend.key(code: modCode, down: false, flags: flags)
        }
    }

    private func holdDown(_ combo: KeyCombo, key: String) {
        guard heldKeys[key] == nil, let resolved = keys.resolve(combo) else { return }
        let code = resolved.code
        heldKeys[key] = (code: code, flags: resolved.flags)
        recomputeHeldFlags()
        // Un modificatore puro genera un flagsChanged; un tasto normale (Spazio) un keyDown.
        backend.key(code: code, down: true, flags: heldFlags)
    }

    private func holdUp(key: String) {
        guard let held = heldKeys.removeValue(forKey: key) else { return }
        recomputeHeldFlags()
        backend.key(code: held.code, down: false, flags: heldFlags)
    }

    private func recomputeHeldFlags() {
        heldFlags = heldKeys.values.reduce(into: CGEventFlags()) { $0.formUnion($1.flags) }
    }

    // MARK: - Touchpad (dito)

    func handleGesture(_ g: GestureMessage) {
        stats.fingerGestures += 1
        guard connected, !cursorLocked else { return }
        // Un nuovo tocco ferma lo scorrimento per inerzia, come su un trackpad vero.
        if g.kind != .gestureEnd && g.kind != .multiEnd { stopMomentum() }
        if profile.mode == .display && handleDisplayGesture(g) { return }
        let opts = profile.trackpad
        let trackpad = profile.mode == .touchpad
        let cursor = backend.cursorLocation
        switch g.kind {
        case .pointerMove:
            moveRelative(dx: Double(g.dx), dy: Double(g.dy), dragging: touchDragging)
        case .dragMove:
            moveRelative(dx: Double(g.dx), dy: Double(g.dy), dragging: touchDragging)
        case .leftClick:
            // Trackpad: un tocco nell'angolo scelto è un clic secondario (dx, dy = posizione del tocco).
            let secondary: Bool = trackpad && opts.secondaryClick.isSecondary(u: Double(g.dx), v: Double(g.dy))
            click(secondary ? .right : .left, count: 1, at: cursor)
        case .rightClick:
            guard !trackpad || opts.secondaryClick == .twoFingers else { return }
            click(.right, count: 1, at: cursor)
        case .doubleClick:
            // Secondo tocco ravvicinato: l'iPad ha già inviato il primo clic,
            // qui si invia il secondo con clickState = 2 (doppio clic per macOS).
            click(.left, count: 2, at: cursor)
        case .dragBegin:
            guard !touchDragging, !trackpad || opts.holdToDrag else { return }
            touchDragging = true
            backend.mouseButton(.left, down: true, at: cursor, clickCount: 1, flags: heldFlags)
        case .dragEnd:
            guard touchDragging else { return }
            touchDragging = false
            backend.mouseButton(.left, down: false, at: cursor, clickCount: 1, flags: heldFlags)
        case .scroll:
            scrollBy(dxPoints: Double(g.dx), dyPoints: Double(g.dy))
        case .pinch:
            guard !trackpad || opts.pinchToZoom else { return }
            // I gesti di zoom "veri" del trackpad non sono generabili con API pubbliche:
            // il pinch viene tradotto nelle scorciatoie di zoom (⌘+ / ⌘− predefinite).
            pinchAccumulator *= Double(g.scale)
            if pinchAccumulator > 1.2 {
                perform(profile.pinchOpenAction, pressed: true, holdKey: "pinch")
                perform(profile.pinchOpenAction, pressed: false, holdKey: "pinch")
                pinchAccumulator = 1
            } else if pinchAccumulator < 1 / 1.2 {
                perform(profile.pinchCloseAction, pressed: true, holdKey: "pinch")
                perform(profile.pinchCloseAction, pressed: false, holdKey: "pinch")
                pinchAccumulator = 1
            }
        case .gestureEnd:
            pinchAccumulator = 1
            endScroll()
        case .multiMove:
            handleMultiMove(g)
        case .multiPinch:
            handleMultiPinch(g)
        case .multiEnd:
            endMulti()
        case .threeFingerTap:
            // Ricerca e rilevatori dati: ⌃⌘D sulla parola sotto il cursore.
            if opts.lookUpThreeFingerTap { tap(KeyCombo.char("d", [.control, .command])) }
        case .pointTo, .tapAt, .doubleTapAt, .rightTapAt:
            break   // solo in modalità Display
        }
    }

    // MARK: - Trackpad

    private func click(_ button: CGMouseButton, count: Int, at point: CGPoint) {
        backend.mouseButton(button, down: true, at: point, clickCount: count, flags: heldFlags)
        backend.mouseButton(button, down: false, at: point, clickCount: count, flags: heldFlags)
    }

    /// Movimento relativo del cursore, con velocità e accelerazione come un trackpad.
    private func moveRelative(dx rawDX: Double, dy rawDY: Double, dragging: Bool) {
        let cursor = backend.cursorLocation
        let speed: Double = profile.touchpadSpeed * (precisionMode ? profile.precisionFactor : 1)
        // Accelerazione leggera: movimenti rapidi coprono più spazio.
        let magnitude: Double = hypot(rawDX, rawDY)
        let accel: Double = 1 + min(magnitude / 25, 1.5)
        let dx = CGFloat(rawDX * speed * accel)
        let dy = CGFloat(rawDY * speed * accel)
        let target = DisplayManager.clamp(CGPoint(x: cursor.x + dx, y: cursor.y + dy),
                                          to: displays, preferring: targetDisplay)
        backend.mouseMove(to: target, delta: CGPoint(x: dx, y: dy), dragging: dragging, flags: heldFlags)
    }

    /// Scorrimento con fasi da trackpad e verso "naturale" a scelta.
    private func scrollBy(dxPoints: Double, dyPoints: Double) {
        let k: Double = profile.scrollSpeed
        let sign: Double = profile.trackpad.naturalScrolling ? 1 : -1
        let dx: Double = dxPoints * k * sign
        let dy: Double = dyPoints * k * sign
        let now = MonotonicClock.now()
        if !scrolling {
            scrolling = true
            scrollVX = 0
            scrollVY = 0
            lastScrollTime = now
            backend.scroll(dx: dx, dy: dy, flags: heldFlags, phase: .began)
            return
        }
        let dt: Double = max(now - lastScrollTime, 0.004)
        lastScrollTime = now
        // Velocità media (pixel al secondo) per l'inerzia.
        let a: Double = 0.35
        scrollVX = scrollVX * (1 - a) + (dx / dt) * a
        scrollVY = scrollVY * (1 - a) + (dy / dt) * a
        backend.scroll(dx: dx, dy: dy, flags: heldFlags, phase: .changed)
    }

    private func endScroll() {
        guard scrolling else { return }
        scrolling = false
        backend.scroll(dx: 0, dy: 0, flags: heldFlags, phase: .ended)
        // Inerzia solo se le dita si stavano ancora muovendo quando si sono sollevate.
        let idle: Double = MonotonicClock.now() - lastScrollTime
        guard profile.trackpad.scrollInertia, idle < 0.08 else { return }
        let limit: Double = 6000
        let vx: Double = min(max(scrollVX, -limit), limit)
        let vy: Double = min(max(scrollVY, -limit), limit)
        guard hypot(vx, vy) > 150 else { return }
        startMomentum(vx: vx, vy: vy)
    }

    private func startMomentum(vx startVX: Double, vy startVY: Double) {
        stopMomentum()
        var vx = startVX
        var vy = startVY
        var first = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let dt: Double = 0.016
            let dx: Double = vx * dt
            let dy: Double = vy * dt
            // Decadimento come l'inerzia di macOS (circa mezzo secondo).
            vx *= 0.94
            vy *= 0.94
            if hypot(vx, vy) < 40 {
                self.stopMomentum()
                return
            }
            self.backend.scroll(dx: dx, dy: dy, flags: self.heldFlags, phase: first ? .momentumBegan : .momentumChanged)
            first = false
        }
        momentumTimer = timer
        momentumStarted = true
        timer.resume()
    }

    private func stopMomentum() {
        guard let timer = momentumTimer else { return }
        timer.cancel()
        momentumTimer = nil
        if momentumStarted {
            momentumStarted = false
            backend.scroll(dx: 0, dy: 0, flags: heldFlags, phase: .momentumEnded)
        }
    }

    /// Tre o quattro dita: trascinamento a tre dita oppure gesti di sistema (una volta per gesto).
    private func handleMultiMove(_ g: GestureMessage) {
        let fingers = Int(g.fingers)
        let opts = profile.trackpad
        if fingers != multiFingers {
            if multiDragging { endThreeFingerDrag() }
            multiFingers = fingers
            multiAccumX = 0
            multiAccumY = 0
            multiFired = false
            multiPinchScale = 1
        }
        if fingers == 3 && opts.threeFingerDrag {
            if !multiDragging {
                multiDragging = true
                touchDragging = true
                backend.mouseButton(.left, down: true, at: backend.cursorLocation, clickCount: 1, flags: heldFlags)
            }
            moveRelative(dx: Double(g.dx), dy: Double(g.dy), dragging: true)
            return
        }
        multiAccumX += Double(g.dx)
        multiAccumY += Double(g.dy)
        guard !multiFired else { return }
        let ax: Double = abs(multiAccumX)
        let ay: Double = abs(multiAccumY)
        guard max(ax, ay) > 70 else { return }
        multiFired = true
        guard let n = GestureFingers(rawValue: fingers), n != .off else { return }
        if ax > ay {
            let towardRight: Bool = multiAccumX > 0
            if opts.swipeBetweenSpaces == n {
                // Dita verso destra = Space a sinistra, come su macOS.
                tap(KeyCombo.key(towardRight ? 123 : 124, [.control]))
            } else if opts.swipeBetweenPages == n {
                // Dita verso destra = pagina precedente.
                tap(KeyCombo.char(towardRight ? "[" : "]", [.command]))
            }
        } else if multiAccumY < 0 {
            if opts.missionControl == n { SystemActions.missionControl() }
        } else {
            if opts.appExpose == n { SystemActions.appExpose() }
        }
    }

    /// Pollice e tre dita: avvicinare = Launchpad / App, allargare = Mostra scrivania.
    private func handleMultiPinch(_ g: GestureMessage) {
        let fingers = Int(g.fingers)
        if fingers != multiFingers {
            multiFingers = fingers
            multiAccumX = 0
            multiAccumY = 0
            multiFired = false
            multiPinchScale = 1
        }
        multiPinchScale *= Double(g.scale)
        guard !multiFired, !multiDragging else { return }
        if multiPinchScale < 0.72 {
            multiFired = true
            if profile.trackpad.launchpad { SystemActions.launchpad() }
        } else if multiPinchScale > 1.4 {
            multiFired = true
            if profile.trackpad.showDesktop { SystemActions.showDesktop() }
        }
    }

    private func endMulti() {
        if multiDragging { endThreeFingerDrag() }
        multiFingers = 0
        multiAccumX = 0
        multiAccumY = 0
        multiFired = false
        multiPinchScale = 1
    }

    private func endThreeFingerDrag() {
        multiDragging = false
        touchDragging = false
        backend.mouseButton(.left, down: false, at: backend.cursorLocation, clickCount: 1, flags: heldFlags)
    }

    // MARK: - Modalità Display: dita

    /// Un dito: trackpad (movimento relativo); tocco e doppio tocco cliccano nel punto toccato.
    /// Due dita: zoom e spostamento dell'area mostrata, oppure gesti per l'app (impostazione del profilo).
    /// `pointTo` (cursore sotto il dito) resta supportato per client che lo inviano.
    /// Restituisce true se il gesto è stato gestito qui.
    private func handleDisplayGesture(_ g: GestureMessage) -> Bool {
        switch g.kind {
        case .pointTo:
            moveCursorUnderFinger(u: Double(g.dx), v: Double(g.dy))
            return true
        case .tapAt, .doubleTapAt, .rightTapAt:
            clickUnderFinger(g)
            return true
        case .pointerMove, .leftClick, .doubleClick, .rightClick, .dragBegin, .dragMove, .dragEnd:
            // Il dito è un trackpad: movimento relativo e clic nel punto del cursore.
            // Mentre la Pencil disegna il dito non interferisce; se la Pencil è solo vicina, cede il cursore.
            if tipDown { return true }
            if inProximity { exitProximity() }
            return false
        case .scroll:
            guard profile.displayGestures == .area else { return false }
            panDisplayRegion(dxPoints: Double(g.dx), dyPoints: Double(g.dy))
            return true
        case .pinch:
            guard profile.displayGestures == .area else { return false }
            zoomDisplayRegion(scale: Double(g.scale), centerU: Double(g.dx), centerV: Double(g.dy))
            return true
        case .gestureEnd:
            guard profile.displayGestures == .area else { return false }
            flushDisplayRegion()
            return true
        default:
            return false
        }
    }

    private func moveCursorUnderFinger(u: Double, v: Double) {
        guard u.isFinite, v.isFinite, !tipDown else { return }
        // La penna in prossimità "possiede" il cursore: prima esce, poi il dito lo sposta.
        if inProximity { exitProximity() }
        let target = DisplayManager.clamp(mapper.absolutePoint(u: u, v: v), to: displays, preferring: targetDisplay)
        let previous = lastCursor ?? backend.cursorLocation
        let delta = CGPoint(x: target.x - previous.x, y: target.y - previous.y)
        backend.mouseMove(to: target, delta: delta, dragging: false, flags: heldFlags)
        lastCursor = target
        stats.cursor = target
    }

    /// Tocco del dito: il cursore va nel punto toccato dell'immagine e lì avviene il clic
    /// (doppio tocco = doppio clic nello stesso punto, due dita = clic destro).
    private func clickUnderFinger(_ g: GestureMessage) {
        let u = Double(g.dx)
        let v = Double(g.dy)
        guard u.isFinite, v.isFinite, !tipDown else { return }
        if inProximity { exitProximity() }
        let target = DisplayManager.clamp(mapper.absolutePoint(u: u, v: v), to: displays, preferring: targetDisplay)
        let previous = lastCursor ?? backend.cursorLocation
        let delta = CGPoint(x: target.x - previous.x, y: target.y - previous.y)
        backend.mouseMove(to: target, delta: delta, dragging: false, flags: heldFlags)
        lastCursor = target
        stats.cursor = target
        let button: CGMouseButton = g.kind == .rightTapAt ? .right : .left
        let count: Int = g.kind == .doubleTapAt ? 2 : 1
        backend.mouseButton(button, down: true, at: target, clickCount: count, flags: heldFlags)
        backend.mouseButton(button, down: false, at: target, clickCount: count, flags: heldFlags)
    }

    /// Dimensione in punti iPad dell'immagine (area di input) sull'iPad.
    private var shownSizePoints: CGSize {
        let r = mapper.inputRect
        return CGSize(width: CGFloat(r.width) * surface.width, height: CGFloat(r.height) * surface.height)
    }

    private func panDisplayRegion(dxPoints: Double, dyPoints: Double) {
        let shown = shownSizePoints
        guard shown.width > 1, shown.height > 1 else { return }
        let r = profile.displayRegion.clamped()
        // Le dita trascinano il contenuto: dita a destra → l'area si sposta a sinistra.
        let dx: Double = -dxPoints / Double(shown.width) * Double(r.width)
        let dy: Double = -dyPoints / Double(shown.height) * Double(r.height)
        setDisplayRegion(DisplayViewport.pan(r, dx: dx, dy: dy))
    }

    private func zoomDisplayRegion(scale: Double, centerU: Double, centerV: Double) {
        let r = profile.displayRegion.clamped()
        let box = mapper.inputRect
        let bw = max(Double(box.width), 1e-6)
        let bh = max(Double(box.height), 1e-6)
        let ax: Double = (centerU - Double(box.x)) / bw
        let ay: Double = (centerV - Double(box.y)) / bh
        setDisplayRegion(DisplayViewport.zoom(r, scale: scale, anchorX: ax, anchorY: ay, fillAspect: displayFillAspect))
    }

    /// Proporzioni dell'area (in coordinate normalizzate sul monitor) che riempiono l'iPad.
    private var displayFillAspect: Double? {
        guard let d = targetDisplay, d.bounds.width > 0, d.bounds.height > 0,
              surface.width > 0, surface.height > 0 else { return nil }
        let surfaceAspect: Double = Double(surface.width / surface.height)
        let displayAspect: Double = Double(d.bounds.width / d.bounds.height)
        return surfaceAspect / displayAspect
    }

    private func setDisplayRegion(_ r: NormRect) {
        guard r != profile.displayRegion else { return }
        profile.displayRegion = r
        reconfigureMapper()
        publishDisplayRegion()
    }

    /// La nuova area va all'iPad subito (max ~60 volte al secondo) e all'app Mac
    /// (cattura, anteprima, salvataggio) ~16 volte al secondo.
    private func publishDisplayRegion() {
        let now = MonotonicClock.now()
        if now - lastRegionConfigSend >= 0.016 {
            lastRegionConfigSend = now
            onSessionConfigChanged?()
        } else if !regionConfigScheduled {
            regionConfigScheduled = true
            queue.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self else { return }
                self.regionConfigScheduled = false
                self.lastRegionConfigSend = MonotonicClock.now()
                self.onSessionConfigChanged?()
            }
        }
        if !regionReportScheduled {
            regionReportScheduled = true
            queue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                self.regionReportScheduled = false
                self.reportDisplayRegion()
            }
        }
    }

    private func flushDisplayRegion() {
        onSessionConfigChanged?()
        reportDisplayRegion()
    }

    private func reportDisplayRegion() {
        let id = profile.id
        let region = profile.displayRegion
        let cb = onDisplayRegionChanged
        DispatchQueue.main.async { cb?(id, region) }
    }

    // MARK: - Configurazione per l'iPad

    func makeSessionConfig() -> SessionConfigMessage {
        SessionConfigMessage(
            mode: profile.mode,
            profileName: profile.name,
            displayName: targetDisplay?.name ?? "—",
            inputRect: mapper.unrotatedInputRect,
            showInputRect: profile.mode == .screen || profile.mode == .display,
            leftHanded: profile.leftHanded,
            // Nessuna barra strumenti sull'iPad: si lavora con Pencil e dita sull'immagine.
            toolbarVisible: false,
            toolbar: [],
            cursorLocked: cursorLocked,
            precisionMode: precisionMode,
            palmRejection: profile.palmRejection,
            eraserActive: eraserActive,
            macCanPostEvents: canPostEvents,
            macRTTms: Float(rttMs),
            mirrorActive: profile.mode == .display,
            mirrorStatus: mirrorStatus,
            mirrorRegion: profile.displayRegion.clamped())
    }

    // MARK: - Notifiche

    private func notify(_ request: EngineRequest) {
        let cb = onRequest
        DispatchQueue.main.async { cb?(request) }
    }

    private func publishStats() {
        let now = MonotonicClock.now()
        stats.sampleRate = rate.rate(at: now)
        stats.inProximity = inProximity
        stats.tipDown = tipDown
        permissionCheckCounter += 1
        if permissionCheckCounter % 10 == 0 {
            let allowed = PermissionManager.canPostEvents
            if allowed != canPostEvents {
                canPostEvents = allowed
                notify(.stateChanged)
            }
        }
        stats.canPostEvents = canPostEvents
        stats.cursorLocked = cursorLocked
        stats.precisionMode = precisionMode
        stats.eraserActive = eraserActive
        let snap = stats
        let cb = onStats
        DispatchQueue.main.async { cb?(snap) }
    }
}
