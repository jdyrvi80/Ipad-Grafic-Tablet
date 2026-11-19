//
//  TabletInputController.swift
//  iPad Graphic Tablet — iPad
//
//  Collega la superficie di cattura alla rete:
//   • numera i campioni (per rilevare perdite sul Mac);
//   • non scarta MAI i campioni a contatto;
//   • in caso di congestione (Wi-Fi lento) dirada solo l'hover → frequenza adattiva;
//   • aggiorna le capacità rilevate e le dimensioni della superficie.
//

import UIKit
import Combine

final class TabletInputController: ObservableObject, PencilSurfaceDelegate {

    let connection: PadConnectionManager
    private let detector = CapabilityDetector()

    @Published private(set) var capabilities: DeviceCapabilities
    @Published var calibration: Calibration {
        didSet {
            calibration.save()
            surface?.calibration = calibration
        }
    }
    /// Ultima posizione della penna (normalizzata) per il punto di riferimento opzionale.
    @Published private(set) var penPoint: CGPoint?
    @Published var showPenDot: Bool {
        didSet { UserDefaults.standard.set(showPenDot, forKey: "showPenDot") }
    }

    weak var surface: PencilSurfaceView? {
        didSet { surface?.calibration = calibration }
    }

    private var sequence: UInt32 = 0
    private var lastDotUpdate: TimeInterval = 0
    private var surfaceSize: CGSize
    private var lastHoverSent: TimeInterval = 0
    private let helloLock = NSLock()
    private var cachedHello: HelloMessage
    let deviceID: String

    init(connection: PadConnectionManager) {
        self.connection = connection
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "deviceID")
        }
        capabilities = detector.capabilities
        calibration = Calibration.load()
        showPenDot = defaults.bool(forKey: "showPenDot")
        let screen = TabletInputController.currentScreen
        surfaceSize = screen?.bounds.size ?? CGSize(width: 1180, height: 820)
        cachedHello = HelloMessage(deviceID: "", deviceName: "", model: "", systemVersion: "",
                                   capabilities: [], surfaceWidth: 0, surfaceHeight: 0, screenScale: 2)
        rebuildHello()
        connection.helloProvider = { [weak self] in
            guard let self else {
                return HelloMessage(deviceID: "?", deviceName: "iPad", model: "", systemVersion: "",
                                    capabilities: [], surfaceWidth: 1024, surfaceHeight: 768, screenScale: 2)
            }
            self.helloLock.lock(); defer { self.helloLock.unlock() }
            return self.cachedHello
        }
    }

    static var currentScreen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }

    var deviceName: String {
        let custom = UserDefaults.standard.string(forKey: "deviceName") ?? ""
        return custom.isEmpty ? UIDevice.current.name : custom
    }

    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func rebuildHello() {
        let hello = HelloMessage(deviceID: deviceID, deviceName: deviceName,
                                 model: TabletInputController.modelIdentifier,
                                 systemVersion: UIDevice.current.systemVersion,
                                 capabilities: detector.capabilities,
                                 surfaceWidth: Float(surfaceSize.width), surfaceHeight: Float(surfaceSize.height),
                                 screenScale: Float(TabletInputController.currentScreen?.scale ?? 2))
        helloLock.lock()
        cachedHello = hello
        helloLock.unlock()
    }

    private func capabilitiesChanged() {
        capabilities = detector.capabilities
        rebuildHello()
        connection.send(.deviceUpdate(DeviceUpdateMessage(capabilities: detector.capabilities,
                                                          surfaceWidth: Float(surfaceSize.width),
                                                          surfaceHeight: Float(surfaceSize.height))))
    }

    /// Il punto di riferimento si aggiorna solo se attivo e al massimo a 60 Hz:
    /// pubblicare a 240 Hz farebbe ricalcolare l'interfaccia SwiftUI a ogni campione.
    private func updateDot(_ p: CGPoint?) {
        guard showPenDot else {
            if penPoint != nil { penPoint = nil }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if p != nil && now - lastDotUpdate < 1.0 / 60.0 { return }
        lastDotUpdate = now
        penPoint = p
    }

    // MARK: - PencilSurfaceDelegate

    func surface(_ surface: PencilSurfaceView, didCapture samples: [PenSample]) {
        var out = samples
        var changed = false
        for i in out.indices {
            if detector.observeContact(out[i]) { changed = true }
            sequence &+= 1
            out[i].sequence = sequence
        }
        // Invio PRIMA di qualsiasi aggiornamento dell'interfaccia: latenza minima.
        connection.send(.penBatch(out))
        if let last = out.last {
            updateDot(last.flags.contains(.strokeEnded) ? nil : CGPoint(x: CGFloat(last.x), y: CGFloat(last.y)))
        }
        if changed { capabilitiesChanged() }
    }

    func surface(_ surface: PencilSurfaceView, didHover sample: PenSample) {
        if detector.observeHover() { capabilitiesChanged() }
        updateDot(CGPoint(x: CGFloat(sample.x), y: CGFloat(sample.y)))
        // Frequenza adattiva: l'hover viene diradato solo se la rete è in difficoltà.
        let backlog = connection.pendingBytes
        if backlog > 64 * 1024 { return }
        let minInterval: TimeInterval = (backlog > 16 * 1024 || connection.rttMs > 25) ? 1.0 / 60.0 : 0
        let now = ProcessInfo.processInfo.systemUptime
        if minInterval > 0 && now - lastHoverSent < minInterval { return }
        lastHoverSent = now
        var s = sample
        sequence &+= 1
        s.sequence = sequence
        connection.send(.penBatch([s]))
    }

    func surfaceHoverEnded(_ surface: PencilSurfaceView) {
        updateDot(nil)
        sequence &+= 1
        let s = PenSample(sequence: sequence, timestamp: ProcessInfo.processInfo.systemUptime,
                          x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, flags: [.proximityOut])
        connection.send(.penBatch([s]))
    }

    func surface(_ surface: PencilSurfaceView, gesture: GestureMessage) {
        connection.send(.gesture(gesture))
    }

    func surface(_ surface: PencilSurfaceView, pencilGesture kind: PencilGestureKind, phase: GesturePhase) {
        let changed = kind == .doubleTap ? detector.observeDoubleTap() : detector.observeSqueeze()
        if changed { capabilitiesChanged() }
        connection.send(.pencilGesture(PencilGestureMessage(kind: kind, phase: phase)))
    }

    func surface(_ surface: PencilSurfaceView, didResize size: CGSize) {
        guard size != surfaceSize else { return }
        surfaceSize = size
        rebuildHello()
        connection.send(.deviceUpdate(DeviceUpdateMessage(capabilities: detector.capabilities,
                                                          surfaceWidth: Float(size.width),
                                                          surfaceHeight: Float(size.height))))
    }

    // MARK: - Barra strumenti e comandi

    func button(_ id: UInt16, pressed: Bool) {
        connection.send(.button(ButtonMessage(buttonID: id, pressed: pressed)))
    }

    func control(_ command: ControlCommand, value: Int32 = 0) {
        connection.send(.control(ControlMessage(command: command, value: value)))
    }

    /// Aggiorna le dimensioni dallo schermo corrente (prima che la superficie esista).
    func refreshScreenSize() {
        guard let size = TabletInputController.currentScreen?.bounds.size, size != surfaceSize,
              size.width > 0, size.height > 0 else { return }
        surfaceSize = size
        rebuildHello()
    }

    func setDeviceName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "deviceName")
        rebuildHello()
    }
}
