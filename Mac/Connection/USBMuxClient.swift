//
//  USBMuxClient.swift
//  iPad Graphic Tablet — Mac
//
//  Collegamento USB tramite usbmuxd, il demone macOS che multiplexa le
//  connessioni verso iPhone/iPad via cavo (lo stesso meccanismo usato da
//  Xcode, Finder e da PeerTalk/Duet Display).
//
//  Flusso:
//   1. socket Unix su /var/run/usbmuxd, messaggio "Listen" → eventi Attached/Detached
//   2. per ogni iPad collegato via USB: nuovo socket, messaggio "Connect" verso la
//      porta 47820 dell'iPad (dove l'app iPad ascolta in loopback)
//   3. risposta "Result 0" → da quel momento il socket è un tunnel TCP trasparente
//
//  Requisiti: app Mac NON sandbox (accesso al socket di sistema) e iPad che ha
//  già autorizzato il Mac ("Autorizza questo computer").
//
//  Nota onesta: il protocollo usbmuxd non è documentato ufficialmente da Apple,
//  ma è stabile da oltre 15 anni ed è usato da prodotti in commercio.
//

import Foundation
import Darwin

final class USBMuxClient {

    struct Device: Equatable, Identifiable {
        let id: Int
        let serial: String
        let productID: Int
        let connectionType: String
    }

    enum ListenState: Equatable {
        case stopped
        case unavailable(String)
        case listening
    }

    private static let socketPath = "/var/run/usbmuxd"
    private static let headerSize = 16
    private static let plistMessageType: UInt32 = 8

    private let queue: DispatchQueue
    private let targetPort: UInt16

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var listenBuffer = Data()
    private var retryTimer: DispatchSourceTimer?
    private var tag: UInt32 = 1

    private(set) var devices: [Int: Device] = [:]
    private var connecting: Set<Int> = []
    private var tunnels: Set<Int> = []
    private var lastAttempt: [Int: Double] = [:]
    private var running = false

    var onDevicesChanged: (([Device]) -> Void)?
    var onListenState: ((ListenState) -> Void)?
    /// Nuovo tunnel pronto verso l'iPad indicato.
    var onTunnel: ((FDTransport, Device) -> Void)?

    init(queue: DispatchQueue, port: UInt16 = TabletWire.usbPort) {
        self.queue = queue
        self.targetPort = port
    }

    // MARK: - Ciclo di vita

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.openListenSocket()
            self.startRetryTimer()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.closeListenSocket()
            self.devices.removeAll()
            self.onDevicesChanged?([])
            self.onListenState?(.stopped)
        }
    }

    /// Da chiamare quando un tunnel si chiude: si potrà ritentare.
    func tunnelClosed(deviceID: Int) {
        queue.async {
            self.tunnels.remove(deviceID)
            self.lastAttempt[deviceID] = MonotonicClock.now()
        }
    }

    // MARK: - Socket

    private func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { cptr in
                _ = strncpy(cptr, USBMuxClient.socketPath, pathCapacity - 1)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func openListenSocket() {
        guard listenFD < 0 else { return }
        guard let fd = makeSocket() else {
            onListenState?(.unavailable("usbmuxd non raggiungibile (\(String(cString: strerror(errno))))"))
            return
        }
        listenFD = fd
        listenBuffer.removeAll()
        guard writePacket(fd: fd, plist: request("Listen")) else {
            closeListenSocket()
            onListenState?(.unavailable("Invio 'Listen' a usbmuxd fallito"))
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readListenSocket() }
        source.setCancelHandler { Darwin.close(fd) }
        listenSource = source
        source.resume()
        onListenState?(.listening)
        tlog.info("USB: in ascolto degli eventi usbmuxd")
    }

    private func closeListenSocket() {
        if let s = listenSource {
            s.cancel()          // chiude il fd nel cancel handler
        } else if listenFD >= 0 {
            Darwin.close(listenFD)
        }
        listenSource = nil
        listenFD = -1
    }

    private func readListenSocket() {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = buf.withUnsafeMutableBytes { Darwin.read(listenFD, $0.baseAddress, $0.count) }
        if n <= 0 {
            tlog.warn("USB: connessione a usbmuxd chiusa, nuovo tentativo a breve")
            closeListenSocket()
            let gone = devices
            devices.removeAll()
            if !gone.isEmpty { onDevicesChanged?([]) }
            onListenState?(.unavailable("usbmuxd ha chiuso la connessione"))
            return
        }
        listenBuffer.append(contentsOf: buf[0..<n])
        // nextPacket: nil = servono altri byte; .some(nil) = pacchetto illeggibile (scartato).
        while let packet = nextPacket(from: &listenBuffer) {
            if let dict = packet { handleListenMessage(dict) }
        }
    }

    private func handleListenMessage(_ msg: [String: Any]) {
        guard let type = msg["MessageType"] as? String else { return }
        switch type {
        case "Result":
            let code = (msg["Number"] as? Int) ?? -1
            if code != 0 { tlog.warn("USB: usbmuxd ha risposto \(code) a Listen") }
        case "Attached":
            guard let id = msg["DeviceID"] as? Int,
                  let props = msg["Properties"] as? [String: Any] else { return }
            let connType = (props["ConnectionType"] as? String) ?? "?"
            // Solo cavo: gli iPad "sincronizzati via Wi-Fi" compaiono come "Network".
            guard connType == "USB" else { return }
            let dev = Device(id: id,
                             serial: (props["SerialNumber"] as? String) ?? "",
                             productID: (props["ProductID"] as? Int) ?? 0,
                             connectionType: connType)
            devices[id] = dev
            lastAttempt[id] = 0
            tlog.info("USB: dispositivo collegato (id \(id))")
            onDevicesChanged?(Array(devices.values))
            attemptConnect(to: dev)
        case "Detached":
            guard let id = msg["DeviceID"] as? Int else { return }
            if devices.removeValue(forKey: id) != nil {
                tlog.info("USB: dispositivo scollegato (id \(id))")
                onDevicesChanged?(Array(devices.values))
            }
            connecting.remove(id)
        default:
            break
        }
    }

    // MARK: - Connessione al servizio dell'iPad

    private func startRetryTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.listenFD < 0 { self.openListenSocket() }
            let now = MonotonicClock.now()
            for dev in self.devices.values
            where !self.tunnels.contains(dev.id) && !self.connecting.contains(dev.id) {
                // L'app iPad potrebbe non essere aperta: si ritenta ogni ~1,5 s.
                if now - (self.lastAttempt[dev.id] ?? 0) >= 1.5 {
                    self.attemptConnect(to: dev)
                }
            }
        }
        retryTimer = t
        t.resume()
    }

    private func attemptConnect(to device: Device) {
        guard running, !connecting.contains(device.id), !tunnels.contains(device.id) else { return }
        connecting.insert(device.id)
        lastAttempt[device.id] = MonotonicClock.now()
        let port = targetPort
        let tagValue = nextTag()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.blockingConnect(deviceID: device.id, port: port, tag: tagValue)
            self.queue.async {
                self.connecting.remove(device.id)
                switch result {
                case .success(let fd):
                    guard self.running, self.devices[device.id] != nil else {
                        Darwin.close(fd)
                        return
                    }
                    self.tunnels.insert(device.id)
                    tlog.info("USB: tunnel aperto verso l'iPad (porta \(port))")
                    let transport = FDTransport(fd: fd, queue: self.queue, label: "USB #\(device.id)")
                    self.onTunnel?(transport, device)
                case .failure(let reason):
                    // Codice 3 = porta chiusa: l'app iPad non è in primo piano. Normale.
                    if !reason.contains("codice 3") {
                        tlog.warn("USB: connessione non riuscita — \(reason)")
                    }
                }
            }
        }
    }

    private enum ConnectResult {
        case success(Int32)
        case failure(String)
    }

    /// Eseguito fuori dalla coda principale: letture bloccanti con timeout.
    private func blockingConnect(deviceID: Int, port: UInt16, tag: UInt32) -> ConnectResult {
        guard let fd = makeSocket() else { return .failure("usbmuxd non raggiungibile") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var req = request("Connect")
        req["DeviceID"] = deviceID
        // La porta va espressa in network byte order (big-endian).
        req["PortNumber"] = Int(port.bigEndian)
        guard writePacket(fd: fd, plist: req, tag: tag) else {
            Darwin.close(fd)
            return .failure("scrittura su usbmuxd fallita")
        }
        // Lettura ESATTA di intestazione + plist: i byte successivi appartengono già al tunnel.
        guard let header = readExactly(fd: fd, count: USBMuxClient.headerSize) else {
            Darwin.close(fd)
            return .failure("nessuna risposta da usbmuxd")
        }
        let length = Int(header.leU32(at: 0))
        guard length >= USBMuxClient.headerSize, length < 1 << 20,
              let body = readExactly(fd: fd, count: length - USBMuxClient.headerSize),
              let plist = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
        else {
            Darwin.close(fd)
            return .failure("risposta usbmuxd non valida")
        }
        let code = (plist["Number"] as? Int) ?? -1
        guard code == 0 else {
            Darwin.close(fd)
            return .failure("usbmuxd codice \(code)")
        }
        // Rimuove il timeout di lettura: ora il socket è il canale dati.
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        return .success(fd)
    }

    // MARK: - Protocollo usbmuxd (plist)

    private func nextTag() -> UInt32 {
        tag &+= 1
        return tag
    }

    private func request(_ type: String) -> [String: Any] {
        [
            "MessageType": type,
            "ClientVersionString": "iPadGraphicTablet-1.0",
            "ProgName": "iPadGraphicTablet",
            "kLibUSBMuxVersion": 3,
        ]
    }

    /// Pacchetto: [u32 lunghezza totale][u32 versione=1][u32 tipo=8 (plist)][u32 tag][plist XML]
    private func writePacket(fd: Int32, plist: [String: Any], tag: UInt32 = 0) -> Bool {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        var w = ByteWriter(capacity: body.count + 16)
        w.u32(UInt32(body.count + USBMuxClient.headerSize))
        w.u32(1)
        w.u32(USBMuxClient.plistMessageType)
        w.u32(tag)
        w.raw(body)
        let packet = w.data
        return packet.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, base + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private func readExactly(fd: Int32, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var out = Data(count: count)
        var got = 0
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while got < count {
                let n = Darwin.read(fd, base + got, count - got)
                if n > 0 { got += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        return ok ? out : nil
    }

    private func nextPacket(from buffer: inout Data) -> [String: Any]?? {
        guard buffer.count >= USBMuxClient.headerSize else { return nil }
        let length = Int(buffer.leU32(at: 0))
        guard length >= USBMuxClient.headerSize, length < 1 << 20 else {
            buffer.removeAll()          // flusso desincronizzato: si riparte da zero
            return nil
        }
        guard buffer.count >= length else { return nil }
        let body = buffer.subdata(in: (buffer.startIndex + USBMuxClient.headerSize) ..< (buffer.startIndex + length))
        buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + length)
        let dict = (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any]
        return .some(dict)
    }
}

private extension Data {
    func leU32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        var value: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(self[base + i])
            value |= byte << UInt32(8 * i)
        }
        return value
    }
}
