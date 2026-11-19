//
//  WebClientServer.swift
//  iPad Graphic Tablet — Mac
//
//  Modalità "senza app": l'iPad apre in Safari http://<IP-del-Mac>:47830
//   • porta 47830 — mini server HTTP che serve WebClient.html (incluso nell'app)
//   • porta 47831 — WebSocket (NWProtocolWebSocket) con lo STESSO protocollo binario
//                   dell'app iPad: dopo l'autenticazione la connessione diventa un
//                   normale PeerChannel e tutto il resto (motore, profili, eventi
//                   tavoletta) funziona senza modifiche.
//
//  Autenticazione: codice a 6 cifre mostrato dal Mac. Il Mac invia un nonce casuale,
//  la pagina risponde con HMAC-SHA256(codice, nonce): il codice non viaggia in rete.
//  Limite dichiarato: su http il traffico NON è cifrato (Safari non può usare TLS-PSK
//  e un certificato autofirmato richiederebbe di installare un profilo sull'iPad).
//

import Foundation
import Network
import CryptoKit

final class WebClientServer {

    static let pagePort: UInt16 = 47830
    static var socketPort: UInt16 { pagePort + 1 }

    enum State: Equatable {
        case stopped
        case ready
        case failed(String)
    }

    private let queue: DispatchQueue
    private var pageListener: NWListener?
    private var socketListener: NWListener?
    private var pageData = Data()
    /// Impronta della pagina servita: una pagina già aperta ma più vecchia si ricarica da sola.
    private var pageVersion = ""
    /// Icona dell'app per la schermata Home dell'iPad ("Aggiungi a Home" da Safari).
    private var iconData = Data()
    /// Codice a 6 cifre (lettura/scrittura solo sulla coda).
    private var accessCode = ""
    private var failures: [Double] = []
    private var lockedUntil: Double = 0

    var onState: ((State) -> Void)?
    /// Connessione autenticata pronta a diventare una sessione.
    var onChannel: ((PeerChannel) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: - Ciclo di vita

    func start(code: String) {
        let loaded = WebClientServer.loadPage()
        queue.async {
            self.stopOnQueue()
            self.accessCode = code
            self.pageVersion = loaded.version
            self.pageData = loaded.data
            self.iconData = WebClientServer.loadIcon()
            let page = loaded.data
            guard !page.isEmpty else {
                self.onState?(.failed("WebClient.html mancante nel bundle"))
                return
            }
            self.pageListener = self.makePageListener()
            self.socketListener = self.makeSocketListener()
        }
    }

    func stop() {
        queue.async {
            self.stopOnQueue()
            self.onState?(.stopped)
        }
    }

    func updateCode(_ code: String) {
        queue.async { self.accessCode = code }
    }

    private func stopOnQueue() {
        pageListener?.stateUpdateHandler = nil
        pageListener?.cancel()
        pageListener = nil
        socketListener?.stateUpdateHandler = nil
        socketListener?.cancel()
        socketListener = nil
    }

    static func loadIcon() -> Data {
        guard let url = Bundle.main.url(forResource: "apple-touch-icon", withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }

    /// Pagina dal bundle con la sua versione (impronta SHA-256) scritta dentro.
    static func loadPage() -> (data: Data, version: String) {
        guard let url = Bundle.main.url(forResource: "WebClient", withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return (Data(), "") }
        let digest = SHA256.hash(data: data)
        let version = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let html = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "__PAGE_VERSION__", with: version)
        return (Data(html.utf8), version)
    }

    static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String(format: "%06u", UInt32.random(in: 0...999_999, using: &rng))
    }

    // MARK: - Server HTTP (solo la pagina)

    private func makePageListener() -> NWListener? {
        let params = NWParameters(tls: nil, tcp: TabletSecurity.tcpOptions())
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: WebClientServer.pagePort),
              let listener = try? NWListener(using: params, on: port) else {
            tlog.error("Web: porta \(WebClientServer.pagePort) non disponibile")
            onState?(.failed("porta \(WebClientServer.pagePort) occupata"))
            return nil
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                tlog.info("Web: pagina disponibile su http://<IP-del-Mac>:\(WebClientServer.pagePort)")
            case .failed(let error):
                tlog.error("Web: server pagina fallito: \(error)")
                self?.onState?(.failed("\(error)"))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        return listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var request = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data { request.append(data) }
                if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(to: request.subdata(in: request.startIndex..<end.lowerBound), on: connection)
                } else if error != nil || isComplete || request.count > 16 * 1024 {
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
        // Nessuna connessione HTTP resta appesa più di 10 secondi.
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let firstLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

        let status: String
        let body: Data
        let type: String
        let iconPaths: Set<String> = ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png",
                                      "/favicon.ico", "/favicon.png"]
        let isIcon: Bool = iconPaths.contains(path)
        if method == "GET" && (path == "/" || path == "/index.html") {
            status = "200 OK"; body = pageData; type = "text/html; charset=utf-8"
        } else if method == "GET" && isIcon && !iconData.isEmpty {
            status = "200 OK"; body = iconData; type = "image/png"
        } else {
            status = "404 Not Found"; body = Data("Non trovato".utf8); type = "text/plain; charset=utf-8"
        }
        // Intestazione costruita riga per riga: una lunga catena di "+" con interpolazioni
        // supera il tempo massimo del type-checker di Swift.
        var lines: [String] = []
        lines.append("HTTP/1.1 " + status)
        lines.append("Content-Type: " + type)
        lines.append("Content-Length: " + String(body.count))
        lines.append("Cache-Control: no-store")
        lines.append("X-Content-Type-Options: nosniff")
        lines.append("Connection: close")
        let header: String = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - WebSocket

    private func makeSocketListener() -> NWListener? {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        let params = NWParameters(tls: nil, tcp: TabletSecurity.tcpOptions())
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        guard let port = NWEndpoint.Port(rawValue: WebClientServer.socketPort),
              let listener = try? NWListener(using: params, on: port) else {
            tlog.error("Web: porta \(WebClientServer.socketPort) non disponibile")
            onState?(.failed("porta \(WebClientServer.socketPort) occupata"))
            return nil
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(.ready)
            case .failed(let error):
                tlog.error("Web: WebSocket fallito: \(error)")
                self?.onState?(.failed("\(error)"))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.authenticate(connection)
        }
        listener.start(queue: queue)
        return listener
    }

    /// Challenge-response prima di consegnare la connessione al ConnectionManager.
    private func authenticate(_ connection: NWConnection) {
        let now = MonotonicClock.now()
        if now < lockedUntil {
            connection.cancel()
            return
        }
        let nonce = TabletSecurity.data(of: SymmetricKey(size: .bits128)).map { String(format: "%02x", $0) }.joined()
        var finished = false

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let version: String = self.pageVersion
                let challenge: String = "{\"t\":\"auth\",\"nonce\":\"\(nonce)\",\"v\":\"\(version)\"}"
                WebSocketTransport.sendText(challenge, on: connection)
                connection.receiveMessage { [weak self] data, context, _, error in
                    guard let self, !finished else { return }
                    finished = true
                    guard error == nil, let data,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["t"] as? String == "auth",
                          let proofHex = obj["proof"] as? String,
                          let proof = Data(hexString: proofHex),
                          HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(nonce.utf8),
                                                                using: SymmetricKey(data: Data(self.accessCode.utf8)))
                    else {
                        self.registerFailure()
                        WebSocketTransport.sendText("{\"t\":\"denied\",\"reason\":\"Codice errato o scaduto.\"}", on: connection)
                        self.queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
                        return
                    }
                    _ = context
                    WebSocketTransport.sendText("{\"t\":\"ok\"}", on: connection)
                    connection.stateUpdateHandler = nil
                    let transport = WebSocketTransport(connection: connection, queue: self.queue)
                    let channel = PeerChannel(kind: .web, transport: transport, queue: self.queue)
                    tlog.info("Web: Safari autenticato da \(connection.endpoint)")
                    self.onChannel?(channel)
                }
            case .failed, .cancelled:
                finished = true
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Senza risposta entro 10 s la connessione viene chiusa.
        queue.asyncAfter(deadline: .now() + 10) {
            if !finished { finished = true; connection.cancel() }
        }
    }

    /// Limite ai tentativi: dopo 5 codici errati in 5 minuti, blocco di 60 secondi.
    private func registerFailure() {
        let now = MonotonicClock.now()
        failures = failures.filter { now - $0 < 300 } + [now]
        tlog.warn("Web: codice errato (\(failures.count) tentativi recenti)")
        if failures.count >= 5 {
            lockedUntil = now + 60
            failures.removeAll()
            tlog.warn("Web: troppi tentativi, accesso bloccato per 60 s")
        }
    }
}

/// Trasporto WebSocket per PeerChannel: ogni frame del protocollo viaggia in un
/// messaggio binario; i messaggi ricevuti vengono passati al decoder come flusso.
final class WebSocketTransport: ByteTransport {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let pending = PendingCounter()
    private var closed = false

    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var pendingBytes: Int { pending.current }
    var peerDescription: String { "Safari \(connection.endpoint)" }

    /// La connessione è già pronta (autenticata): si parte direttamente con la ricezione.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.closed else { return }
            if let error { self.finish(error); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { self.finish(nil); return }
            if data == nil && context == nil { self.finish(nil); return }   // connessione chiusa
            if let data, !data.isEmpty, metadata?.opcode != .text {
                self.onReceive?(data)
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        let count = data.count
        pending.add(count)
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pending.add(-count)
            if let error { self.finish(error) }
        })
    }

    static func sendText(_ text: String, on connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func close() {
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        onReceive = nil
        handler?(error)
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.hexValue(chars[i]), let lo = Data.hexValue(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48          // 0-9
        case 97...102: return c - 87         // a-f
        case 65...70: return c - 55          // A-F
        default: return nil
        }
    }
}
