//
//  PadConnectionManager.swift
//  iPad Graphic Tablet — iPad
//
//  Lato iPad del collegamento:
//   • USB  — listener TCP su 127.0.0.1:47820. Il Mac lo raggiunge con usbmuxd
//            attraverso il cavo: nessuna configurazione, basta collegare.
//   • Wi-Fi — ricerca Bonjour dei Mac, TLS-PSK con la chiave ricevuta in
//             associazione (via USB in automatico, oppure con PIN), IP manuale.
//  USB ha la precedenza; riconnessione automatica in caso di interruzione.
//

import Foundation
import Combine
import Network
import CryptoKit
import UIKit

struct DiscoveredMac: Identifiable, Hashable {
    var id: String            // macID (dal record TXT) o nome del servizio
    var name: String
    var endpoint: NWEndpoint?
    var pairingEndpoint: NWEndpoint?
    var isPaired: Bool
}

struct PairedMac: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var lastHost: String?
}

enum PadLinkState: Equatable {
    case idle
    case paused
    case connecting(String)
    case connected(LinkKind, String)
    case failed(String)
}

final class PadConnectionManager: ObservableObject {

    @Published private(set) var state: PadLinkState = .idle
    @Published private(set) var discovered: [DiscoveredMac] = []
    @Published private(set) var paired: [PairedMac] = []
    @Published private(set) var config: SessionConfigMessage?
    @Published private(set) var rttMs: Double = 0
    @Published private(set) var usbListening = false
    @Published var message: String?
    @Published var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }

    let queue = DispatchQueue(label: "pad.net", qos: .userInteractive)
    /// Fotogrammi dello schermo del Mac (modalità Display).
    let mirrorFeed = MirrorFeed()

    // Stato di rete (solo sulla coda `queue`)
    private var usbListener: NWListener?
    private var browser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private var active: PeerChannel?
    private var activeLink: LinkKind?
    private var pending: [UUID: (channel: PeerChannel, purpose: Purpose)] = [:]
    private var wifiTarget: WiFiTarget?
    private var reconnectTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var latency = LatencyStats()
    private var pingID: UInt32 = 0
    private var paused = false
    private var servicesByID: [String: NWEndpoint] = [:]
    private var pairingServicesByID: [String: NWEndpoint] = [:]
    private var namesByID: [String: String] = [:]
    /// Copia degli ID associati usata sulla coda di rete (evita accessi concorrenti a `paired`).
    private var pairedIDs: Set<String> = []
    /// Host inserito a mano per l'ultima associazione (per collegarsi subito dopo senza Bonjour).
    private var lastPairingHost: String?
    /// Ultimo Mac collegato via USB: se il cavo viene staccato si prova a proseguire in Wi-Fi.
    private var lastUSBMac: (id: String, name: String)?
    /// Se il binding esplicito su 127.0.0.1 non è accettato, si ascolta su tutte le
    /// interfacce filtrando comunque le connessioni non locali.
    private var usbBindAllInterfaces = false

    /// Canale attivo leggibile da qualsiasi thread (per l'invio dei campioni).
    private let activeLock = NSLock()
    private var activeForSend: PeerChannel?

    private enum Purpose { case session, pairing }

    private struct WiFiTarget {
        var macID: String
        var name: String
        var endpoint: NWEndpoint
    }

    /// Fornisce il messaggio di saluto aggiornato (capacità, dimensioni superficie).
    var helloProvider: (() -> HelloMessage)?
    var onSessionChange: ((Bool) -> Void)?

    init() {
        autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true
        let loaded = PadConnectionManager.loadPaired()
        paired = loaded
        pairedIDs = Set(loaded.map(\.id))
    }

    // MARK: - Avvio

    func start() {
        queue.async {
            self.paused = false
            self.startUSBListener()
            self.startBrowsers()
            self.startReconnectTimer()
        }
        setState(.idle)
    }

    /// Uscita dalla modalità tavoletta: niente riconnessioni finché l'utente non riprende.
    func pause() {
        queue.async {
            self.paused = true
            self.wifiTarget = nil
            self.lastUSBMac = nil
            self.usbListener?.cancel()
            self.usbListener = nil
            self.active?.close(reason: "Sessione chiusa dall'iPad")
            for p in self.pending.values { p.channel.close() }
            self.pending.removeAll()
            DispatchQueue.main.async { self.usbListening = false }
        }
        setState(.paused)
    }

    func resume() {
        start()
    }

    /// L'app è tornata in primo piano: i listener potrebbero essere stati invalidati.
    func applicationBecameActive() {
        queue.async {
            guard !self.paused else { return }
            if self.usbListener == nil { self.startUSBListener() }
            if self.browser == nil { self.startBrowsers() }
        }
    }

    // MARK: - USB

    private func startUSBListener() {
        guard usbListener == nil, let port = NWEndpoint.Port(rawValue: TabletWire.usbPort) else { return }
        let params = TabletSecurity.plainParameters()
        params.allowLocalEndpointReuse = true
        do {
            let listener: NWListener
            if usbBindAllInterfaces {
                listener = try NWListener(using: params, on: port)
            } else {
                // Solo loopback: il tunnel usbmuxd arriva come connessione locale.
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                listener = try NWListener(using: params)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    tlog.info("USB: in ascolto su 127.0.0.1:\(TabletWire.usbPort)")
                    DispatchQueue.main.async { self.usbListening = true }
                case .failed(let error):
                    tlog.error("USB: listener fallito: \(error)")
                    listener?.cancel()
                    if self.usbListener === listener { self.usbListener = nil }
                    self.usbBindAllInterfaces = true
                    DispatchQueue.main.async { self.usbListening = false }
                    // Nuovo tentativo tra poco (es. porta ancora occupata dopo il background).
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        if !self.paused && self.usbListener == nil { self.startUSBListener() }
                    }
                case .cancelled:
                    if self.usbListener === listener { self.usbListener = nil }
                    DispatchQueue.main.async { self.usbListening = false }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                // Difesa in profondità: si accettano solo connessioni locali (il tunnel usbmuxd).
                guard PadConnectionManager.isLoopback(connection.endpoint) else {
                    tlog.warn("USB: rifiutata connessione non locale da \(connection.endpoint)")
                    connection.cancel()
                    return
                }
                let transport = NWTransport(connection: connection, queue: self.queue)
                let channel = PeerChannel(kind: .usb, transport: transport, queue: self.queue)
                tlog.info("USB: il Mac si è collegato")
                self.adopt(channel, purpose: .session, macName: "Mac (USB)")
            }
            listener.start(queue: queue)
            usbListener = listener
        } catch {
            tlog.error("USB: impossibile creare il listener: \(error)")
            if !usbBindAllInterfaces {
                usbBindAllInterfaces = true
                queue.asyncAfter(deadline: .now() + 0.5) { self.startUSBListener() }
            }
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback || address.asIPv4 == .loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    // MARK: - Bonjour

    private func startBrowsers() {
        browser?.cancel()
        pairingBrowser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: .bonjourWithTXTRecord(type: TabletWire.bonjourService, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updateServices(results, pairing: false)
        }
        b.stateUpdateHandler = { state in
            if case .failed(let e) = state { tlog.error("Bonjour: ricerca fallita: \(e)") }
        }
        b.start(queue: queue)
        browser = b

        let pb = NWBrowser(for: .bonjourWithTXTRecord(type: TabletWire.bonjourPairingService, domain: nil), using: params)
        pb.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updateServices(results, pairing: true)
        }
        pb.start(queue: queue)
        pairingBrowser = pb
    }

    private func updateServices(_ results: Set<NWBrowser.Result>, pairing: Bool) {
        var map: [String: NWEndpoint] = [:]
        for r in results {
            var id: String?
            if case .bonjour(let txt) = r.metadata { id = txt["id"] }
            var name = "Mac"
            if case .service(let serviceName, _, _, _) = r.endpoint { name = serviceName }
            let key = id ?? "name:\(name)"
            map[key] = r.endpoint
            namesByID[key] = name
        }
        if pairing { pairingServicesByID = map } else { servicesByID = map }
        publishDiscovered()
    }

    private func publishDiscovered() {
        var all: [String: DiscoveredMac] = [:]
        for (id, ep) in servicesByID {
            all[id] = DiscoveredMac(id: id, name: namesByID[id] ?? "Mac", endpoint: ep,
                                    pairingEndpoint: pairingServicesByID[id], isPaired: pairedIDs.contains(id))
        }
        for (id, ep) in pairingServicesByID where all[id] == nil {
            all[id] = DiscoveredMac(id: id, name: namesByID[id] ?? "Mac", endpoint: nil,
                                    pairingEndpoint: ep, isPaired: pairedIDs.contains(id))
        }
        let list = all.values.sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.discovered = list }
    }

    // MARK: - Wi-Fi

    func connect(to mac: DiscoveredMac) {
        guard let endpoint = mac.endpoint else {
            setMessage("Questo Mac è visibile solo in modalità associazione: inserisci il codice.")
            return
        }
        queue.async { self.connectWiFi(macID: mac.id, name: mac.name, endpoint: endpoint) }
    }

    /// Connessione a un IP inserito a mano, con la chiave del Mac associato scelto.
    func connectManual(host: String, macID: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let port = NWEndpoint.Port(rawValue: TabletWire.wifiPort) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmed), port: port)
        let name = paired.first(where: { $0.id == macID })?.name ?? trimmed
        queue.async { self.connectWiFi(macID: macID, name: name, endpoint: endpoint) }
    }

    private func connectWiFi(macID: String, name: String, endpoint: NWEndpoint) {
        guard !paused else { return }
        if activeLink == .usb { return }   // l'USB ha la precedenza
        guard let keyData = KeychainStore.load(account: "mac-\(macID)") else {
            setMessage("\(name) non è ancora associato: collega l'iPad via cavo una volta oppure usa il codice.")
            return
        }
        wifiTarget = WiFiTarget(macID: macID, name: name, endpoint: endpoint)
        if active != nil || pending.values.contains(where: { $0.channel.kind == .wifi }) { return }
        setState(.connecting(name))
        let params = TabletSecurity.tlsParameters(key: SymmetricKey(data: keyData))
        let connection = NWConnection(to: endpoint, using: params)
        let transport = NWTransport(connection: connection, queue: queue)
        let channel = PeerChannel(kind: .wifi, transport: transport, queue: queue)
        adopt(channel, purpose: .session, macName: name)
    }

    /// Associazione con PIN: endpoint del servizio di associazione (Bonjour) o host manuale.
    func pair(macName: String, pairingEndpoint: NWEndpoint?, manualHost: String?, pin: String) {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 6 else { setMessage("Il codice è di 6 cifre."); return }
        var endpoint = pairingEndpoint
        if endpoint == nil, let host = manualHost?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
           let port = NWEndpoint.Port(rawValue: TabletWire.pairingPort) {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        guard let target = endpoint else {
            setMessage("Avvia l'associazione sul Mac: Connessione → Associa un iPad con codice.")
            return
        }
        let manual = pairingEndpoint == nil ? manualHost?.trimmingCharacters(in: .whitespaces) : nil
        queue.async {
            self.lastPairingHost = manual
            self.setState(.connecting("Associazione con \(macName)…"))
            let params = TabletSecurity.tlsParameters(key: TabletSecurity.pairingKey(pin: digits))
            let connection = NWConnection(to: target, using: params)
            let transport = NWTransport(connection: connection, queue: self.queue)
            let channel = PeerChannel(kind: .wifi, transport: transport, queue: self.queue)
            self.adopt(channel, purpose: .pairing, macName: macName)
        }
    }

    func forget(_ mac: PairedMac) {
        KeychainStore.delete(account: "mac-\(mac.id)")
        paired.removeAll { $0.id == mac.id }
        PadConnectionManager.savePaired(paired)
        queue.async {
            self.pairedIDs.remove(mac.id)
            if self.wifiTarget?.macID == mac.id { self.wifiTarget = nil }
            self.publishDiscovered()
        }
    }

    // MARK: - Canali

    private func adopt(_ channel: PeerChannel, purpose: Purpose, macName: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending[channel.id] = (channel, purpose)
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            self.handle(message, from: channel, purpose: purpose)
        }
        channel.onClose = { [weak self, weak channel] error in
            guard let self, let channel else { return }
            self.closed(channel, purpose: purpose, error: error, macName: macName)
        }
        channel.start()
        // Il saluto parte subito: TCP/TLS accodano finché la connessione non è pronta.
        if let hello = helloProvider?() {
            channel.send(.hello(hello))
        }
    }

    private func handle(_ message: TabletMessage, from channel: PeerChannel, purpose: Purpose) {
        switch message {
        case .welcome(let w):
            guard w.accepted else {
                setMessage(w.reason.isEmpty ? "Il Mac ha rifiutato la connessione." : w.reason)
                channel.close()
                return
            }
            if purpose == .pairing { return }   // si attende la chiave
            activate(channel, macID: w.macID, macName: w.macName)

        case .pairingKey(let k):
            guard k.key.count == 32 else { return }
            KeychainStore.save(k.key, account: "mac-\(k.macID)")
            pairedIDs.insert(k.macID)
            publishDiscovered()
            let entry = PairedMac(id: k.macID, name: k.macName, lastHost: nil)
            DispatchQueue.main.async {
                self.paired.removeAll { $0.id == k.macID }
                self.paired.append(entry)
                PadConnectionManager.savePaired(self.paired)
            }
            tlog.info("Associazione Wi-Fi salvata per \(k.macName)")
            if purpose == .pairing {
                setMessage("Associato a \(k.macName). Connessione in corso…")
                // Subito dopo l'associazione ci si collega alla porta delle sessioni.
                queue.asyncAfter(deadline: .now() + 0.4) {
                    var ep = self.servicesByID[k.macID]
                    if ep == nil, let host = self.lastPairingHost, let port = NWEndpoint.Port(rawValue: TabletWire.wifiPort) {
                        ep = .hostPort(host: NWEndpoint.Host(host), port: port)
                    }
                    if let ep {
                        self.connectWiFi(macID: k.macID, name: k.macName, endpoint: ep)
                    }
                }
            }

        case .sessionConfig(let cfg):
            DispatchQueue.main.async { self.config = cfg }

        case .ping(let p):
            channel.sendOnQueue(.pong(PongMessage(id: p.id, sentAt: p.sentAt, peerTime: MonotonicClock.now())))

        case .pong(let p):
            latency.record(sentAt: p.sentAt, receivedAt: MonotonicClock.now(), peerTime: p.peerTime)
            let avg = latency.summary.avgMs
            DispatchQueue.main.async { self.rttMs = avg }

        case .bye(let reason):
            if !reason.isEmpty { setMessage(reason) }
            channel.close()

        case .videoFrame(let frame):
            mirrorFeed.receive(frame) { [weak channel] id in
                channel?.send(.frameAck(id))
            }

        default:
            break
        }
    }

    private func activate(_ channel: PeerChannel, macID: String, macName: String) {
        pending[channel.id] = nil
        if let current = active, current !== channel {
            if channel.kind == .usb || current.kind == channel.kind {
                current.close(reason: "Passaggio a \(channel.kind.rawValue)")
            } else {
                // Arriva il Wi-Fi mentre c'è l'USB: si resta su USB.
                channel.close(reason: "Già collegato via USB")
                return
            }
        }
        active = channel
        activeLink = channel.kind
        activeLock.lock(); activeForSend = channel; activeLock.unlock()
        latency.reset()
        startPing(on: channel)
        if channel.kind == .usb { lastUSBMac = (macID, macName) }
        if channel.kind == .wifi, let target = wifiTarget, target.macID != macID {
            wifiTarget = WiFiTarget(macID: macID, name: macName, endpoint: target.endpoint)
        }
        tlog.info("Sessione attiva con \(macName) via \(channel.kind.rawValue)")
        setState(.connected(channel.kind, macName))
        DispatchQueue.main.async { self.onSessionChange?(true) }
    }

    private func closed(_ channel: PeerChannel, purpose: Purpose, error: Error?, macName: String) {
        pending[channel.id] = nil
        guard active === channel else {
            if purpose == .pairing, error != nil {
                setMessage("Associazione non riuscita: codice errato o scaduto.")
                setState(.failed("Associazione non riuscita"))
            } else if channel.kind == .wifi, active == nil, let error {
                tlog.warn("Wi-Fi: connessione a \(macName) non riuscita: \(error)")
                if !paused { setState(.failed("Mac non raggiungibile")) }
            }
            return
        }
        active = nil
        activeLink = nil
        activeLock.lock(); activeForSend = nil; activeLock.unlock()
        pingTimer?.cancel()
        pingTimer = nil
        tlog.info("Sessione terminata\(error.map { ": \($0)" } ?? "")")
        mirrorFeed.clear()
        DispatchQueue.main.async {
            self.config = nil
            self.onSessionChange?(false)
        }
        setState(paused ? .paused : .idle)
    }

    private func startPing(on channel: PeerChannel) {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 2.0, leeway: .milliseconds(50))
        t.setEventHandler { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.pingID &+= 1
            channel.sendOnQueue(.ping(PingMessage(id: self.pingID, sentAt: MonotonicClock.now())))
        }
        pingTimer = t
        t.resume()
    }

    /// Riconnessione automatica al Mac Wi-Fi usato per ultimo.
    private func startReconnectTimer() {
        reconnectTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, !self.paused, self.active == nil, self.pending.isEmpty else { return }
            guard UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true else { return }
            if let target = self.wifiTarget {
                let endpoint = self.servicesByID[target.macID] ?? target.endpoint
                self.connectWiFi(macID: target.macID, name: target.name, endpoint: endpoint)
            } else if let usbMac = self.lastUSBMac, self.pairedIDs.contains(usbMac.id),
                      let endpoint = self.servicesByID[usbMac.id] {
                // Cavo staccato: si prosegue in Wi-Fi con lo stesso Mac (associato via USB).
                self.connectWiFi(macID: usbMac.id, name: usbMac.name, endpoint: endpoint)
            }
        }
        reconnectTimer = t
        t.resume()
    }

    /// Chiusura volontaria dall'iPad.
    func disconnect() {
        queue.async {
            self.wifiTarget = nil
            self.lastUSBMac = nil
            self.active?.close(reason: "Sessione chiusa dall'iPad")
        }
    }

    // MARK: - Invio

    /// Byte in coda sul canale attivo (controllo di congestione).
    var pendingBytes: Int {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeForSend?.pendingBytes ?? 0
    }

    var isConnected: Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeForSend != nil
    }

    func send(_ message: TabletMessage) {
        activeLock.lock()
        let channel = activeForSend
        activeLock.unlock()
        channel?.send(message)
    }

    // MARK: - Utilità

    private func setState(_ s: PadLinkState) {
        DispatchQueue.main.async { self.state = s }
    }

    private func setMessage(_ text: String) {
        DispatchQueue.main.async { self.message = text }
    }

    private static func loadPaired() -> [PairedMac] {
        guard let data = UserDefaults.standard.data(forKey: "pairedMacs"),
              let list = try? JSONDecoder().decode([PairedMac].self, from: data) else { return [] }
        // Si tengono solo i Mac di cui esiste davvero la chiave nel Portachiavi.
        return list.filter { KeychainStore.load(account: "mac-\($0.id)") != nil }
    }

    private static func savePaired(_ list: [PairedMac]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "pairedMacs")
        }
    }
}
