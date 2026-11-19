//
//  PeerChannel.swift
//  TabletLink
//
//  Canale di messaggi sopra un ByteTransport: framing, decodifica,
//  invio thread-safe e gestione della chiusura. Tutti i callback
//  arrivano sulla coda del canale (seriale, QoS userInteractive).
//

import Foundation
import Network

public enum LinkKind: String {
    case usb = "USB"
    case wifi = "Wi-Fi"
    /// Pagina web in Safari (nessuna app sull'iPad), WebSocket sulla rete locale.
    case web = "Safari"
}

public final class PeerChannel {
    public let kind: LinkKind
    public let queue: DispatchQueue
    private let transport: ByteTransport
    private var decoder = FrameDecoder()
    private var closed = false

    public var onMessage: ((TabletMessage) -> Void)?
    public var onClose: ((Error?) -> Void)?

    /// Identificativo per log/diagnostica.
    public let id = UUID()
    public var peerDescription: String { transport.peerDescription }

    public init(kind: LinkKind, transport: ByteTransport, queue: DispatchQueue) {
        self.kind = kind
        self.transport = transport
        self.queue = queue
    }

    public var isClosed: Bool { closed }

    /// Byte in coda di invio: se crescono la rete è congestionata.
    public var pendingBytes: Int { transport.pendingBytes }

    public func start() {
        transport.onReceive = { [weak self] data in
            self?.ingest(data)
        }
        transport.onClose = { [weak self] error in
            self?.handleClose(error)
        }
        transport.start()
    }

    private func ingest(_ data: Data) {
        guard !closed else { return }
        decoder.append(data)
        do {
            while let frame = try decoder.nextFrame() {
                let message = try TabletMessage.decode(type: frame.type, payload: frame.payload)
                onMessage?(message)
                if closed { return }
            }
        } catch {
            // Flusso corrotto o versione incompatibile: non si tenta di risincronizzare.
            close(reason: "Errore di protocollo: \(error)")
        }
    }

    /// Invia un messaggio. Può essere chiamato da qualsiasi thread.
    public func send(_ message: TabletMessage) {
        let frame = message.framed()
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.transport.send(frame)
        }
    }

    /// Invio diretto quando si è già sulla coda del canale (evita un salto di coda).
    public func sendOnQueue(_ message: TabletMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        transport.send(message.framed())
    }

    public func close(reason: String = "") {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            if !reason.isEmpty {
                // Tentativo di cortesia: il peer saprà perché chiudiamo.
                self.transport.send(TabletMessage.bye(reason).framed())
            }
            // Piccolo margine perché il "bye" parta prima della chiusura.
            self.queue.asyncAfter(deadline: .now() + 0.05) {
                self.transport.close()
                self.handleClose(nil)
            }
        }
    }

    private func handleClose(_ error: Error?) {
        guard !closed else { return }
        closed = true
        let handler = onClose
        onClose = nil
        onMessage = nil
        handler?(error)
    }
}
