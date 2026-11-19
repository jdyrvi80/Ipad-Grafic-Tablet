//
//  WiFiServer.swift
//  iPad Graphic Tablet — Mac
//
//  Due listener Network.framework pubblicati via Bonjour:
//   • sessioni   — porta 47821, TLS-PSK con la chiave a lungo termine
//   • associazione — porta 47822, TLS-PSK con chiave derivata dal PIN,
//                    attivo solo per 2 minuti quando l'utente lo richiede
//  Se una porta fissa è occupata si ripiega su una porta casuale
//  (Bonjour continua a funzionare; l'IP manuale no).
//

import Foundation
import Network
import CryptoKit

final class WiFiServer {

    enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    private let queue: DispatchQueue
    private var sessionListener: NWListener?
    private var pairingListener: NWListener?
    private var pairingTimer: DispatchSourceTimer?
    private var pairingFailures = 0

    private(set) var macID = ""
    private(set) var serviceName = ""

    var onState: ((State) -> Void)?
    var onPairingState: ((_ active: Bool) -> Void)?
    /// Nuova connessione TCP+TLS accettata. `pairing` = arrivata sul listener di associazione.
    var onChannel: ((PeerChannel, _ pairing: Bool) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: - Listener sessioni

    func start(key: SymmetricKey, macID: String, serviceName: String) {
        queue.async {
            self.stopSessionListener()
            self.macID = macID
            self.serviceName = serviceName
            self.onState?(.starting)
            self.sessionListener = self.makeListener(params: TabletSecurity.tlsParameters(key: key),
                                                     preferredPort: TabletWire.wifiPort,
                                                     serviceType: TabletWire.bonjourService,
                                                     pairing: false)
        }
    }

    func stop() {
        queue.async {
            self.stopSessionListener()
            self.stopPairingOnQueue()
            self.onState?(.stopped)
        }
    }

    private func stopSessionListener() {
        sessionListener?.stateUpdateHandler = nil
        sessionListener?.cancel()
        sessionListener = nil
    }

    // MARK: - Associazione con PIN

    func startPairing(pin: String, duration: TimeInterval = 120) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopPairingOnQueue()
            self.pairingFailures = 0
            self.pairingListener = self.makeListener(params: TabletSecurity.tlsParameters(key: TabletSecurity.pairingKey(pin: pin)),
                                                     preferredPort: TabletWire.pairingPort,
                                                     serviceType: TabletWire.bonjourPairingService,
                                                     pairing: true)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + duration)
            t.setEventHandler { [weak self] in
                tlog.info("Wi-Fi: finestra di associazione scaduta")
                self?.stopPairingOnQueue()
            }
            self.pairingTimer = t
            t.resume()
            self.onPairingState?(true)
        }
    }

    func stopPairing() {
        queue.async { self.stopPairingOnQueue() }
    }

    private func stopPairingOnQueue() {
        pairingTimer?.cancel()
        pairingTimer = nil
        if pairingListener != nil {
            pairingListener?.stateUpdateHandler = nil
            pairingListener?.cancel()
            pairingListener = nil
            onPairingState?(false)
        }
    }

    /// Un handshake fallito sul listener di associazione (PIN errato):
    /// dopo 5 tentativi la finestra si chiude, contro gli attacchi a forza bruta.
    func registerPairingFailure() {
        queue.async {
            self.pairingFailures += 1
            if self.pairingFailures >= 5 {
                tlog.warn("Wi-Fi: troppi tentativi di associazione falliti, finestra chiusa")
                self.stopPairingOnQueue()
            }
        }
    }

    // MARK: - Costruzione listener

    private func makeListener(params: NWParameters, preferredPort: UInt16,
                              serviceType: String, pairing: Bool) -> NWListener? {
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            if let port = NWEndpoint.Port(rawValue: preferredPort) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            tlog.warn("Wi-Fi: porta \(preferredPort) non disponibile (\(error)), uso una porta casuale")
            do {
                listener = try NWListener(using: params)
            } catch {
                tlog.error("Wi-Fi: impossibile creare il listener: \(error)")
                if !pairing { onState?(.failed("\(error)")) }
                return nil
            }
        }

        let txt = NWTXTRecord(["id": macID, "v": "\(TabletWire.protocolVersion)"])
        listener.service = NWListener.Service(name: serviceName, type: serviceType, domain: nil, txtRecord: txt.data)

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener?.port?.rawValue ?? 0
                tlog.info("Wi-Fi: \(pairing ? "associazione" : "sessioni") in ascolto sulla porta \(port)")
                if !pairing { self.onState?(.ready(port: port)) }
            case .failed(let error):
                tlog.error("Wi-Fi: listener fallito: \(error)")
                if !pairing { self.onState?(.failed("\(error)")) }
                listener?.cancel()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let transport = NWTransport(connection: connection, queue: self.queue)
            let channel = PeerChannel(kind: .wifi, transport: transport, queue: self.queue)
            self.onChannel?(channel, pairing)
        }
        listener.start(queue: queue)
        return listener
    }
}
