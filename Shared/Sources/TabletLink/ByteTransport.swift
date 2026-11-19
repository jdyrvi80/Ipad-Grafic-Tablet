//
//  ByteTransport.swift
//  TabletLink — codice di rete condiviso Mac/iPad (Network.framework)
//
//  Astrazione minima su un flusso di byte bidirezionale.
//  Implementazioni:
//   • NWTransport  — NWConnection (Wi-Fi con TLS-PSK, loopback USB lato iPad)
//   • FDTransport  — socket POSIX (tunnel usbmuxd lato Mac, vedi Mac/Connection)
//

import Foundation
import Network

public protocol ByteTransport: AnyObject {
    /// Chiamato sulla coda del trasporto quando arrivano byte.
    var onReceive: ((Data) -> Void)? { get set }
    /// Chiamato una sola volta alla chiusura (errore nil = chiusura ordinata).
    var onClose: ((Error?) -> Void)? { get set }
    /// Byte accodati ma non ancora consegnati al sistema (per il controllo di flusso).
    var pendingBytes: Int { get }
    /// Descrizione dell'altro capo (per i log).
    var peerDescription: String { get }
    func start()
    func send(_ data: Data)
    func close()
}

/// Contatore thread-safe dei byte in uscita.
final class PendingCounter {
    private var value = 0
    private let lock = NSLock()
    func add(_ n: Int) { lock.lock(); value += n; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Trasporto basato su NWConnection.
public final class NWTransport: ByteTransport {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private let pending = PendingCounter()
    private var closed = false
    /// Chiamato quando la connessione (incluso l'handshake TLS) è pronta.
    public var onReady: (() -> Void)?
    public var onReceive: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public var pendingBytes: Int { pending.current }

    public var peerDescription: String {
        "\(connection.endpoint)"
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveLoop()
            case .failed(let error):
                self.finish(error)
            case .waiting(let error):
                // Su una connessione punto-punto "waiting" significa che il peer non è
                // raggiungibile (o TLS rifiutato): si chiude e si lascia riprovare
                // alla logica di riconnessione, che è più prevedibile.
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.onReceive?(data)
            }
            if let error {
                self.finish(error)
                return
            }
            if isComplete {
                self.finish(nil)
                return
            }
            self.receiveLoop()
        }
    }

    /// Da chiamare sulla coda del trasporto.
    public func send(_ data: Data) {
        guard !closed else { return }
        let count = data.count
        pending.add(count)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pending.add(-count)
            if let error { self.finish(error) }
        })
    }

    public func close() {
        guard !closed else { return }
        connection.cancel()
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel() // idempotente
        let handler = onClose
        onClose = nil
        onReceive = nil
        onReady = nil
        handler?(error)
    }
}
