//
//  ConnectionManager.swift
//  iPad Graphic Tablet — Mac
//
//  Orchestra USB e Wi-Fi, gestisce l'handshake e decide quale sessione è attiva.
//  Regole:
//   • una sola sessione attiva alla volta;
//   • USB ha la precedenza: se arriva l'USB mentre si è in Wi-Fi, si passa all'USB;
//   • lo stesso iPad che si riconnette sostituisce la propria sessione precedente.
//

import Foundation
import Network
import CryptoKit
import SystemConfiguration

/// Fotografia dello stato di connessione per l'interfaccia.
struct ConnectionSnapshot: Equatable {
    enum Phase: Equatable { case idle, waiting, connected }
    var phase: Phase = .idle
    var link: LinkKind?
    var deviceName = ""
    var deviceModel = ""
    var systemVersion = ""
    var capabilities: DeviceCapabilities = []
    var surfaceSize = CGSize(width: 0, height: 0)
    var latency = LatencySummary()
    var usbDevicesAttached = 0
    var usbStatus = "—"
    var wifiStatus = "—"
    var wifiPort: UInt16 = 0
    var pairingActive = false
    var webStatus = "—"
    var screenScale: Double = 2
}

/// Sessione con un iPad (USB o Wi-Fi).
final class MacSession {
    enum Purpose { case normal, pairing }

    let channel: PeerChannel
    let purpose: Purpose
    var hello: HelloMessage?
    var isActive = false
    var latency = LatencyStats()
    private var pingID: UInt32 = 0
    private var pingTimer: DispatchSourceTimer?
    private var helloTimer: DispatchSourceTimer?

    var link: LinkKind { channel.kind }

    init(channel: PeerChannel, purpose: Purpose) {
        self.channel = channel
        self.purpose = purpose
    }

    func startTimers(onHelloTimeout: @escaping () -> Void, onPing: @escaping () -> Void) {
        let h = DispatchSource.makeTimerSource(queue: channel.queue)
        h.schedule(deadline: .now() + 6)
        h.setEventHandler { [weak self] in
            guard let self, self.hello == nil else { return }
            onHelloTimeout()
        }
        helloTimer = h
        h.resume()

        let p = DispatchSource.makeTimerSource(queue: channel.queue)
        p.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(20))
        p.setEventHandler(handler: onPing)
        pingTimer = p
        p.resume()
    }

    func nextPing() -> PingMessage {
        pingID &+= 1
        return PingMessage(id: pingID, sentAt: MonotonicClock.now())
    }

    func stopTimers() {
        helloTimer?.cancel(); helloTimer = nil
        pingTimer?.cancel(); pingTimer = nil
    }
}

final class ConnectionManager {

    /// Coda unica per rete e motore di input: niente lock sul percorso critico.
    let queue = DispatchQueue(label: "tablet.core", qos: .userInteractive)

    private let usb: USBMuxClient
    private let wifi: WiFiServer
    private let web: WebClientServer
    private let engine: TabletEngine

    private var sessions: [UUID: MacSession] = [:]
    private(set) var active: MacSession?
    private var snapshot = ConnectionSnapshot()

    let macID: String
    let macName: String
    private var sessionKey: SymmetricKey

    var usbEnabled = true
    var wifiEnabled = true
    var webEnabled = true
    /// Codice a 6 cifre per la pagina Safari.
    var webCode = ""

    /// Notifiche verso l'interfaccia (sempre sul main thread).
    var onSnapshot: ((ConnectionSnapshot) -> Void)?
    var onControl: ((ControlMessage) -> Void)?
    /// Conferma di un fotogramma dello schermo (chiamato sulla coda di rete).
    var onFrameAck: ((UInt32) -> Void)?

    init(engine: TabletEngine) {
        self.engine = engine
        self.usb = USBMuxClient(queue: queue)
        self.wifi = WiFiServer(queue: queue)
        self.web = WebClientServer(queue: queue)

        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "macID") {
            macID = id
        } else {
            macID = UUID().uuidString
            defaults.set(macID, forKey: "macID")
        }
        // Nome di condivisione del Mac (es. "MacBook Pro di Jody"), senza query DNS lente.
        macName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

        if let data = KeychainStore.load(account: "wifi-session-key"), data.count == 32 {
            sessionKey = SymmetricKey(data: data)
        } else {
            sessionKey = TabletSecurity.newLongTermKey()
            KeychainStore.save(TabletSecurity.data(of: sessionKey), account: "wifi-session-key")
        }

        engine.attach(queue: queue)
        // Zoom/spostamento dell'area in modalità Display: la configurazione parte subito, già sulla coda.
        engine.onSessionConfigChanged = { [weak self] in self?.sendConfigOnQueue() }
        wireCallbacks()
    }

    private func wireCallbacks() {
        usb.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            self.snapshot.usbDevicesAttached = devices.count
            self.publish()
        }
        usb.onListenState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .stopped: self.snapshot.usbStatus = "Disattivato"
            case .listening: self.snapshot.usbStatus = "In ascolto (usbmuxd)"
            case .unavailable(let why): self.snapshot.usbStatus = "Non disponibile: \(why)"
            }
            self.publish()
        }
        usb.onTunnel = { [weak self] transport, device in
            guard let self else { return }
            let channel = PeerChannel(kind: .usb, transport: transport, queue: self.queue)
            self.adopt(channel: channel, purpose: .normal, usbDeviceID: device.id)
        }
        wifi.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .stopped: self.snapshot.wifiStatus = "Disattivato"; self.snapshot.wifiPort = 0
            case .starting: self.snapshot.wifiStatus = "Avvio…"
            case .ready(let port): self.snapshot.wifiStatus = "In ascolto"; self.snapshot.wifiPort = port
            case .failed(let why): self.snapshot.wifiStatus = "Errore: \(why)"
            }
            self.publish()
        }
        wifi.onPairingState = { [weak self] active in
            guard let self else { return }
            self.snapshot.pairingActive = active
            self.publish()
        }
        wifi.onChannel = { [weak self] channel, pairing in
            self?.adopt(channel: channel, purpose: pairing ? .pairing : .normal, usbDeviceID: nil)
        }
        web.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .stopped: self.snapshot.webStatus = "Disattivato"
            case .ready: self.snapshot.webStatus = "In ascolto"
            case .failed(let why): self.snapshot.webStatus = "Errore: \(why)"
            }
            self.publish()
        }
        web.onChannel = { [weak self] channel in
            self?.adopt(channel: channel, purpose: .normal, usbDeviceID: nil)
        }
    }

    // MARK: - Avvio / arresto

    func start() {
        if usbEnabled { usb.start() }
        if wifiEnabled { wifi.start(key: sessionKey, macID: macID, serviceName: macName) }
        if webEnabled { web.start(code: webCode) }
        queue.async { self.snapshot.phase = .waiting; self.publish() }
    }

    func setWeb(enabled: Bool) {
        webEnabled = enabled
        if enabled { web.start(code: webCode) } else { web.stop(); closeSessions(of: .web) }
    }

    func setWebCode(_ code: String) {
        webCode = code
        web.updateCode(code)
    }

    func setUSB(enabled: Bool) {
        usbEnabled = enabled
        if enabled { usb.start() } else { usb.stop(); closeSessions(of: .usb) }
    }

    func setWiFi(enabled: Bool) {
        wifiEnabled = enabled
        if enabled { wifi.start(key: sessionKey, macID: macID, serviceName: macName) }
        else { wifi.stop(); closeSessions(of: .wifi) }
    }

    func stopAll() {
        usb.stop()
        wifi.stop()
        web.stop()
        queue.async {
            for s in self.sessions.values { s.channel.close(reason: "Il Mac ha chiuso la sessione") }
        }
    }

    private func closeSessions(of kind: LinkKind) {
        queue.async {
            for s in self.sessions.values where s.link == kind {
                s.channel.close(reason: "Collegamento \(kind.rawValue) disattivato sul Mac")
            }
        }
    }

    // MARK: - Associazione

    /// Avvia la finestra di associazione e restituisce il PIN da mostrare.
    func beginPairing() -> String {
        let pin = TabletSecurity.newPIN()
        wifi.startPairing(pin: pin)
        tlog.info("Wi-Fi: associazione aperta per 2 minuti")
        return pin
    }

    func cancelPairing() { wifi.stopPairing() }

    /// Genera una nuova chiave: tutti gli iPad associati via Wi-Fi dovranno riassociarsi.
    func revokeAllPairings() {
        let newKey = TabletSecurity.newLongTermKey()
        KeychainStore.save(TabletSecurity.data(of: newKey), account: "wifi-session-key")
        let restart = wifiEnabled
        queue.async {
            // La chiave è letta sulla coda di rete durante l'handshake: si sostituisce lì.
            self.sessionKey = newKey
            for s in self.sessions.values where s.link == .wifi {
                s.channel.close(reason: "Associazioni revocate sul Mac")
            }
            if restart { self.wifi.start(key: newKey, macID: self.macID, serviceName: self.macName) }
            tlog.info("Wi-Fi: associazioni revocate, nuova chiave generata")
        }
    }

    // MARK: - Sessioni

    private func adopt(channel: PeerChannel, purpose: MacSession.Purpose, usbDeviceID: Int?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let session = MacSession(channel: channel, purpose: purpose)
        sessions[channel.id] = session

        channel.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        channel.onClose = { [weak self, weak session] error in
            guard let self, let session else { return }
            self.sessionClosed(session, error: error, usbDeviceID: usbDeviceID)
        }
        session.startTimers(
            onHelloTimeout: { [weak session] in
                tlog.warn("Sessione \(channel.kind.rawValue): nessun saluto entro 6 s, chiusa")
                session?.channel.close(reason: "Timeout handshake")
            },
            onPing: { [weak self, weak session] in
                guard let self, let session, session.hello != nil else { return }
                session.channel.sendOnQueue(.ping(session.nextPing()))
                if session.isActive {
                    self.snapshot.latency = session.latency.summary
                    self.engine.updateLatency(session.latency.summary.avgMs)
                    self.publish()
                }
            })
        channel.start()
        tlog.info("Nuova connessione \(channel.kind.rawValue) da \(channel.peerDescription)")
    }

    private func handle(_ message: TabletMessage, from session: MacSession) {
        switch message {
        case .hello(let hello):
            handleHello(hello, session: session)

        case .penBatch(let samples):
            guard session.isActive else { return }
            engine.handlePen(samples)

        case .gesture(let g):
            guard session.isActive else { return }
            engine.handleGesture(g)

        case .button(let b):
            guard session.isActive else { return }
            engine.handleButton(b)

        case .pencilGesture(let g):
            guard session.isActive else { return }
            engine.handlePencilGesture(g)

        case .control(let c):
            guard session.isActive else { return }
            if c.command == .toggleEraser {
                engine.toggleEraser()
            } else {
                let cb = onControl
                DispatchQueue.main.async { cb?(c) }
            }

        case .deviceUpdate(let u):
            guard session.isActive else { return }
            session.hello?.capabilities = u.capabilities
            session.hello?.surfaceWidth = u.surfaceWidth
            session.hello?.surfaceHeight = u.surfaceHeight
            engine.updateDevice(capabilities: u.capabilities,
                                surface: CGSize(width: CGFloat(u.surfaceWidth), height: CGFloat(u.surfaceHeight)))
            snapshot.capabilities = u.capabilities
            snapshot.surfaceSize = CGSize(width: CGFloat(u.surfaceWidth), height: CGFloat(u.surfaceHeight))
            publish()
            sendConfig()

        case .ping(let p):
            session.channel.sendOnQueue(.pong(PongMessage(id: p.id, sentAt: p.sentAt, peerTime: MonotonicClock.now())))

        case .pong(let p):
            session.latency.record(sentAt: p.sentAt, receivedAt: MonotonicClock.now(), peerTime: p.peerTime)
            if session.isActive { engine.updateClockOffset(session.latency.clockOffset) }

        case .bye(let reason):
            tlog.info("L'iPad ha chiuso la sessione: \(reason)")
            session.channel.close()

        case .frameAck(let id):
            guard session.isActive else { return }
            onFrameAck?(id)

        case .welcome, .sessionConfig, .pairingKey, .videoFrame:
            break   // messaggi Mac → iPad: ignorati se ricevuti
        }
    }

    private func handleHello(_ hello: HelloMessage, session: MacSession) {
        guard hello.protocolVersion == TabletWire.protocolVersion else {
            session.channel.sendOnQueue(.welcome(WelcomeMessage(macID: macID, macName: macName, accepted: false,
                                                                reason: "Versione protocollo diversa: aggiorna entrambe le app")))
            session.channel.close()
            return
        }
        session.hello = hello

        // Associazione via PIN: si consegna la chiave e si chiude.
        if session.purpose == .pairing {
            session.channel.sendOnQueue(.welcome(WelcomeMessage(macID: macID, macName: macName, accepted: true,
                                                                reason: "Associazione completata")))
            session.channel.sendOnQueue(.pairingKey(PairingKeyMessage(macID: macID, macName: macName,
                                                                      key: TabletSecurity.data(of: sessionKey))))
            tlog.info("Associazione completata con \(hello.deviceName)")
            wifi.stopPairing()
            session.channel.close(reason: "Associazione completata")
            return
        }

        // Scelta della sessione attiva.
        if let current = active, current !== session {
            let sameDevice = current.hello?.deviceID == hello.deviceID
            if session.link == .usb || sameDevice {
                // USB batte Wi-Fi; lo stesso iPad sostituisce la propria sessione.
                tlog.info("Passaggio a \(session.link.rawValue) per \(hello.deviceName)")
                deactivate(current)
                current.channel.close(reason: sameDevice ? "Sostituita da una nuova connessione \(session.link.rawValue)"
                                                         : "Un iPad collegato via USB ha la precedenza")
            } else if current.link == .usb {
                session.channel.sendOnQueue(.welcome(WelcomeMessage(macID: macID, macName: macName, accepted: false,
                                                                    reason: "Il Mac è già in uso via USB da \(current.hello?.deviceName ?? "un altro iPad")")))
                session.channel.close()
                return
            } else {
                // Due iPad in Wi-Fi: vince il più recente.
                deactivate(current)
                current.channel.close(reason: "Un altro iPad si è collegato")
            }
        }

        session.isActive = true
        active = session
        session.channel.sendOnQueue(.welcome(WelcomeMessage(macID: macID, macName: macName, accepted: true)))
        if session.link == .usb {
            // Canale fisico fidato: si consegna anche la chiave Wi-Fi (associazione automatica).
            session.channel.sendOnQueue(.pairingKey(PairingKeyMessage(macID: macID, macName: macName,
                                                                      key: TabletSecurity.data(of: sessionKey))))
        }

        engine.deviceConnected(hello: hello, link: session.link)
        snapshot.phase = .connected
        snapshot.link = session.link
        snapshot.deviceName = hello.deviceName
        snapshot.deviceModel = hello.model
        snapshot.systemVersion = hello.systemVersion
        snapshot.capabilities = hello.capabilities
        snapshot.surfaceSize = CGSize(width: CGFloat(hello.surfaceWidth), height: CGFloat(hello.surfaceHeight))
        snapshot.screenScale = Double(hello.screenScale)
        snapshot.latency = LatencySummary()
        publish()
        sendConfig()
        tlog.info("Sessione attiva: \(hello.deviceName) via \(session.link.rawValue)")
    }

    private func deactivate(_ session: MacSession) {
        guard session.isActive else { return }
        session.isActive = false
        if active === session {
            active = nil
            engine.deviceDisconnected()
        }
    }

    private func sessionClosed(_ session: MacSession, error: Error?, usbDeviceID: Int?) {
        session.stopTimers()
        sessions[session.channel.id] = nil
        if let id = usbDeviceID { usb.tunnelClosed(deviceID: id) }
        if session.purpose == .pairing && session.hello == nil && error != nil {
            // Handshake TLS fallito sulla porta di associazione: PIN errato.
            wifi.registerPairingFailure()
        }
        let wasActive = session.isActive
        deactivate(session)
        if wasActive {
            tlog.info("Sessione \(session.link.rawValue) terminata\(error.map { ": \($0)" } ?? "")")
            snapshot.phase = .waiting
            snapshot.link = nil
            snapshot.deviceName = ""
            snapshot.capabilities = []
            publish()
        }
    }

    // MARK: - Schermo (modalità Display)

    /// Invia un fotogramma alla sessione attiva, se il client sa mostrarlo.
    func sendVideoFrame(_ frame: VideoFrameMessage) {
        queue.async {
            guard let s = self.active,
                  let caps = s.hello?.capabilities, caps.contains(.videoDisplay) else { return }
            s.channel.sendOnQueue(.videoFrame(frame))
        }
    }

    // MARK: - Configurazione verso l'iPad

    /// Invia all'iPad la configurazione corrente (modalità, barra strumenti, area…).
    func sendConfig() {
        queue.async { self.sendConfigOnQueue() }
    }

    private func sendConfigOnQueue() {
        guard let s = active else { return }
        s.channel.sendOnQueue(.sessionConfig(engine.makeSessionConfig()))
    }

    private func publish() {
        let snap = snapshot
        let cb = onSnapshot
        DispatchQueue.main.async { cb?(snap) }
    }
}
