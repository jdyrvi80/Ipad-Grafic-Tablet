//
//  Messages.swift
//  TabletCore
//
//  Tutti i messaggi scambiati tra iPad e Mac.
//  Ogni messaggio viaggia in un frame: [u32 lunghezza][u8 tipo][payload].
//  Vedi docs/PROTOCOLLO.md per la specifica completa.
//

import Foundation

public enum MessageType: UInt8 {
    case hello = 1          // iPad → Mac
    case welcome = 2        // Mac → iPad
    case sessionConfig = 3  // Mac → iPad
    case penBatch = 4       // iPad → Mac
    case gesture = 5        // iPad → Mac (modalità touchpad)
    case button = 6         // iPad → Mac (barra strumenti)
    case pencilGesture = 7  // iPad → Mac (doppio tocco / squeeze)
    case control = 8        // iPad → Mac (comandi rapidi)
    case ping = 9           // entrambi
    case pong = 10          // entrambi
    case pairingKey = 11    // Mac → iPad (solo su canale fidato: USB o PIN)
    case deviceUpdate = 12  // iPad → Mac (capacità / dimensioni cambiate)
    case bye = 13           // entrambi
    case videoFrame = 14    // Mac → iPad (modalità Display: fotogramma JPEG dello schermo)
    case frameAck = 15      // iPad → Mac (fotogramma mostrato: controllo di flusso)
}

// MARK: - Payload

public struct HelloMessage: Equatable {
    public var protocolVersion: UInt16
    public var deviceID: String
    public var deviceName: String
    public var model: String
    public var systemVersion: String
    public var capabilities: DeviceCapabilities
    /// Dimensione della superficie in punti (orientamento corrente).
    public var surfaceWidth: Float
    public var surfaceHeight: Float
    public var screenScale: Float

    public init(protocolVersion: UInt16 = TabletWire.protocolVersion, deviceID: String, deviceName: String,
                model: String, systemVersion: String, capabilities: DeviceCapabilities,
                surfaceWidth: Float, surfaceHeight: Float, screenScale: Float) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.model = model
        self.systemVersion = systemVersion
        self.capabilities = capabilities
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.screenScale = screenScale
    }
}

public struct WelcomeMessage: Equatable {
    public var protocolVersion: UInt16
    public var macID: String
    public var macName: String
    public var accepted: Bool
    public var reason: String

    public init(protocolVersion: UInt16 = TabletWire.protocolVersion, macID: String, macName: String,
                accepted: Bool, reason: String = "") {
        self.protocolVersion = protocolVersion
        self.macID = macID
        self.macName = macName
        self.accepted = accepted
        self.reason = reason
    }
}

/// Descrizione di un pulsante della barra strumenti, inviata all'iPad
/// (l'associazione pulsante → tasti resta sul Mac).
public struct ToolbarItemInfo: Equatable, Identifiable {
    public var id: UInt16
    public var label: String
    public var symbol: String
    public var isHold: Bool

    public init(id: UInt16, label: String, symbol: String, isHold: Bool) {
        self.id = id; self.label = label; self.symbol = symbol; self.isHold = isHold
    }
}

public struct SessionConfigMessage: Equatable {
    public var mode: TabletMode
    public var profileName: String
    public var displayName: String
    /// Area di input effettiva in coordinate NON ruotate dell'iPad (da disegnare in modalità Schermo).
    public var inputRect: NormRect
    public var showInputRect: Bool
    public var leftHanded: Bool
    public var toolbarVisible: Bool
    public var toolbar: [ToolbarItemInfo]
    public var cursorLocked: Bool
    public var precisionMode: Bool
    public var palmRejection: Bool
    public var eraserActive: Bool
    /// Il Mac ha il permesso di generare eventi (Accessibilità).
    public var macCanPostEvents: Bool
    /// Latenza andata/ritorno misurata dal Mac, in ms (solo informativa).
    public var macRTTms: Float
    /// Modalità Display: il Mac invia l'immagine dello schermo da mostrare dentro `inputRect`.
    public var mirrorActive: Bool
    /// Messaggio di stato della trasmissione schermo (es. permesso mancante), vuoto se tutto ok.
    public var mirrorStatus: String
    /// Area del monitor mostrata ORA dentro `inputRect` (normalizzata sul monitor).
    /// Cambia con lo zoom e lo spostamento a due dita; i fotogrammi riportano la propria area.
    public var mirrorRegion: NormRect

    public init(mode: TabletMode, profileName: String, displayName: String, inputRect: NormRect,
                showInputRect: Bool, leftHanded: Bool, toolbarVisible: Bool, toolbar: [ToolbarItemInfo],
                cursorLocked: Bool, precisionMode: Bool, palmRejection: Bool, eraserActive: Bool,
                macCanPostEvents: Bool, macRTTms: Float, mirrorActive: Bool = false, mirrorStatus: String = "",
                mirrorRegion: NormRect = .full) {
        self.mode = mode
        self.profileName = profileName
        self.displayName = displayName
        self.inputRect = inputRect
        self.showInputRect = showInputRect
        self.leftHanded = leftHanded
        self.toolbarVisible = toolbarVisible
        self.toolbar = toolbar
        self.cursorLocked = cursorLocked
        self.precisionMode = precisionMode
        self.palmRejection = palmRejection
        self.eraserActive = eraserActive
        self.macCanPostEvents = macCanPostEvents
        self.macRTTms = macRTTms
        self.mirrorActive = mirrorActive
        self.mirrorStatus = mirrorStatus
        self.mirrorRegion = mirrorRegion
    }
}

/// Fotogramma dello schermo del Mac (JPEG).
public struct VideoFrameMessage: Equatable {
    public var frameID: UInt32
    /// Istante di cattura sull'orologio del Mac (secondi).
    public var captureTime: Double
    public var width: UInt16
    public var height: UInt16
    /// 1 = JPEG
    public var format: UInt8
    public var data: Data
    /// Area del monitor contenuta nel fotogramma (normalizzata sul monitor).
    public var region: NormRect

    public init(frameID: UInt32, captureTime: Double, width: UInt16, height: UInt16, format: UInt8 = 1, data: Data,
                region: NormRect = .full) {
        self.frameID = frameID
        self.captureTime = captureTime
        self.width = width
        self.height = height
        self.format = format
        self.data = data
        self.region = region
    }
}

/// Gesti del dito (modalità touchpad), già riconosciuti dall'iPad.
public enum GestureKind: UInt8 {
    case pointerMove = 0   // dx, dy in punti iPad
    case leftClick = 1     // modalità Trackpad: dx, dy = posizione normalizzata del tocco (angoli = clic secondario)
    case rightClick = 2
    case doubleClick = 3
    case dragBegin = 4
    case dragMove = 5      // dx, dy
    case dragEnd = 6
    case scroll = 7        // dx, dy in punti iPad
    case pinch = 8         // scale (moltiplicativo rispetto all'evento precedente); dx, dy = centro delle dita normalizzato (0…1)
    case gestureEnd = 9
    /// Modalità Display: il cursore va sotto il dito. dx, dy = posizione normalizzata (0…1) sulla superficie.
    case pointTo = 10
    /// Modalità Display: clic sinistro nel punto toccato. dx, dy = posizione normalizzata (0…1).
    case tapAt = 11
    /// Doppio clic nel punto toccato (secondo tocco). dx, dy = posizione del primo tocco.
    case doubleTapAt = 12
    /// Clic destro nel punto toccato con due dita. dx, dy = centro delle dita.
    case rightTapAt = 13
    /// Tre o quattro dita che si muovono insieme: dx, dy = spostamento del centro in punti, fingers = dita.
    case multiMove = 14
    /// Fine del gesto a tre/quattro dita (fingers = dita).
    case multiEnd = 15
    /// Pizzico a quattro o più dita (pollice e tre dita): scale relativa all'evento precedente.
    case multiPinch = 16
    /// Tocco con tre dita (Ricerca e rilevatori dati).
    case threeFingerTap = 17
}

public struct GestureMessage: Equatable {
    public var kind: GestureKind
    public var dx: Float
    public var dy: Float
    public var scale: Float
    public var fingers: UInt8

    public init(kind: GestureKind, dx: Float = 0, dy: Float = 0, scale: Float = 1, fingers: UInt8 = 1) {
        self.kind = kind; self.dx = dx; self.dy = dy; self.scale = scale; self.fingers = fingers
    }
}

public struct ButtonMessage: Equatable {
    public var buttonID: UInt16
    public var pressed: Bool
    public init(buttonID: UInt16, pressed: Bool) { self.buttonID = buttonID; self.pressed = pressed }
}

public enum PencilGestureKind: UInt8 { case doubleTap = 0, squeeze = 1 }
public enum GesturePhase: UInt8 { case began = 0, changed = 1, ended = 2, cancelled = 3 }

public struct PencilGestureMessage: Equatable {
    public var kind: PencilGestureKind
    public var phase: GesturePhase
    public init(kind: PencilGestureKind, phase: GesturePhase) { self.kind = kind; self.phase = phase }
}

public enum ControlCommand: UInt8 {
    case setMode = 0          // value = TabletMode.rawValue
    case nextProfile = 1
    case toggleCursorLock = 2
    case togglePrecision = 3
    case setToolbarVisible = 4 // value = 0/1
    case toggleEraser = 5
}

public struct ControlMessage: Equatable {
    public var command: ControlCommand
    public var value: Int32
    public init(command: ControlCommand, value: Int32 = 0) { self.command = command; self.value = value }
}

public struct PingMessage: Equatable {
    public var id: UInt32
    /// Istante di invio sull'orologio del mittente (secondi).
    public var sentAt: Double
    public init(id: UInt32, sentAt: Double) { self.id = id; self.sentAt = sentAt }
}

public struct PongMessage: Equatable {
    public var id: UInt32
    /// Eco del sentAt del ping.
    public var sentAt: Double
    /// Istante di ricezione del ping sull'orologio di chi risponde (per stimare l'offset).
    public var peerTime: Double
    public init(id: UInt32, sentAt: Double, peerTime: Double) {
        self.id = id; self.sentAt = sentAt; self.peerTime = peerTime
    }
}

public struct PairingKeyMessage: Equatable {
    public var macID: String
    public var macName: String
    /// Chiave TLS-PSK a lungo termine (32 byte) per le sessioni Wi-Fi.
    public var key: Data
    public init(macID: String, macName: String, key: Data) {
        self.macID = macID; self.macName = macName; self.key = key
    }
}

public struct DeviceUpdateMessage: Equatable {
    public var capabilities: DeviceCapabilities
    public var surfaceWidth: Float
    public var surfaceHeight: Float
    public init(capabilities: DeviceCapabilities, surfaceWidth: Float, surfaceHeight: Float) {
        self.capabilities = capabilities; self.surfaceWidth = surfaceWidth; self.surfaceHeight = surfaceHeight
    }
}

// MARK: - Messaggio

public enum TabletMessage: Equatable {
    case hello(HelloMessage)
    case welcome(WelcomeMessage)
    case sessionConfig(SessionConfigMessage)
    case penBatch([PenSample])
    case gesture(GestureMessage)
    case button(ButtonMessage)
    case pencilGesture(PencilGestureMessage)
    case control(ControlMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case pairingKey(PairingKeyMessage)
    case deviceUpdate(DeviceUpdateMessage)
    case bye(String)
    case videoFrame(VideoFrameMessage)
    case frameAck(UInt32)

    public var type: MessageType {
        switch self {
        case .hello: return .hello
        case .welcome: return .welcome
        case .sessionConfig: return .sessionConfig
        case .penBatch: return .penBatch
        case .gesture: return .gesture
        case .button: return .button
        case .pencilGesture: return .pencilGesture
        case .control: return .control
        case .ping: return .ping
        case .pong: return .pong
        case .pairingKey: return .pairingKey
        case .deviceUpdate: return .deviceUpdate
        case .bye: return .bye
        case .videoFrame: return .videoFrame
        case .frameAck: return .frameAck
        }
    }

    /// Frame completo pronto per il trasporto.
    public func framed() -> Data {
        var w = ByteWriter(capacity: 64)
        encodePayload(into: &w)
        return Framing.frame(type: type.rawValue, payload: w.data)
    }

    public func encodePayload(into w: inout ByteWriter) {
        switch self {
        case .hello(let m):
            w.u16(m.protocolVersion)
            w.string(m.deviceID)
            w.string(m.deviceName)
            w.string(m.model)
            w.string(m.systemVersion)
            w.u16(m.capabilities.rawValue)
            w.f32(m.surfaceWidth)
            w.f32(m.surfaceHeight)
            w.f32(m.screenScale)

        case .welcome(let m):
            w.u16(m.protocolVersion)
            w.string(m.macID)
            w.string(m.macName)
            w.bool(m.accepted)
            w.string(m.reason)

        case .sessionConfig(let m):
            w.u8(m.mode.rawValue)
            w.string(m.profileName)
            w.string(m.displayName)
            m.inputRect.encode(into: &w)
            w.bool(m.showInputRect)
            w.bool(m.leftHanded)
            w.bool(m.toolbarVisible)
            w.u16(UInt16(min(m.toolbar.count, 64)))
            for item in m.toolbar.prefix(64) {
                w.u16(item.id)
                w.string(item.label)
                w.string(item.symbol)
                w.bool(item.isHold)
            }
            w.bool(m.cursorLocked)
            w.bool(m.precisionMode)
            w.bool(m.palmRejection)
            w.bool(m.eraserActive)
            w.bool(m.macCanPostEvents)
            w.f32(m.macRTTms)
            w.bool(m.mirrorActive)
            w.string(m.mirrorStatus)
            m.mirrorRegion.encode(into: &w)

        case .penBatch(let samples):
            let n = min(samples.count, Int(UInt16.max))
            w.u16(UInt16(n))
            for s in samples.prefix(n) { s.encode(into: &w) }

        case .gesture(let m):
            w.u8(m.kind.rawValue)
            w.f32(m.dx)
            w.f32(m.dy)
            w.f32(m.scale)
            w.u8(m.fingers)

        case .button(let m):
            w.u16(m.buttonID)
            w.bool(m.pressed)

        case .pencilGesture(let m):
            w.u8(m.kind.rawValue)
            w.u8(m.phase.rawValue)

        case .control(let m):
            w.u8(m.command.rawValue)
            w.i32(m.value)

        case .ping(let m):
            w.u32(m.id)
            w.f64(m.sentAt)

        case .pong(let m):
            w.u32(m.id)
            w.f64(m.sentAt)
            w.f64(m.peerTime)

        case .pairingKey(let m):
            w.string(m.macID)
            w.string(m.macName)
            w.blob(m.key)

        case .deviceUpdate(let m):
            w.u16(m.capabilities.rawValue)
            w.f32(m.surfaceWidth)
            w.f32(m.surfaceHeight)

        case .bye(let reason):
            w.string(reason)

        case .videoFrame(let m):
            w.u32(m.frameID)
            w.f64(m.captureTime)
            w.u16(m.width)
            w.u16(m.height)
            w.u8(m.format)
            w.blob(m.data)
            m.region.encode(into: &w)

        case .frameAck(let id):
            w.u32(id)
        }
    }

    public static func decode(type rawType: UInt8, payload: Data) throws -> TabletMessage {
        guard let type = MessageType(rawValue: rawType) else {
            throw CodecError.unknownMessage(rawType)
        }
        var r = ByteReader(payload)
        switch type {
        case .hello:
            let version = try r.u16()
            return .hello(HelloMessage(
                protocolVersion: version,
                deviceID: try r.string(),
                deviceName: try r.string(),
                model: try r.string(),
                systemVersion: try r.string(),
                capabilities: DeviceCapabilities(rawValue: try r.u16()),
                surfaceWidth: try r.f32(),
                surfaceHeight: try r.f32(),
                screenScale: try r.f32()))

        case .welcome:
            return .welcome(WelcomeMessage(
                protocolVersion: try r.u16(),
                macID: try r.string(),
                macName: try r.string(),
                accepted: try r.bool(),
                reason: try r.string()))

        case .sessionConfig:
            guard let mode = TabletMode(rawValue: try r.u8()) else {
                throw CodecError.invalidValue("modalità")
            }
            let profileName = try r.string()
            let displayName = try r.string()
            let rect = try NormRect.decode(from: &r)
            let showRect = try r.bool()
            let leftHanded = try r.bool()
            let toolbarVisible = try r.bool()
            let count = Int(try r.u16())
            var items: [ToolbarItemInfo] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(ToolbarItemInfo(id: try r.u16(), label: try r.string(),
                                             symbol: try r.string(), isHold: try r.bool()))
            }
            let locked = try r.bool()
            let precision = try r.bool()
            let palm = try r.bool()
            let eraser = try r.bool()
            let canPost = try r.bool()
            let rtt = try r.f32()
            // Campi aggiunti per la modalità Display: assenti nei messaggi di versioni precedenti.
            var mirror = false
            var mirrorStatus = ""
            var mirrorRegion = NormRect.full
            if !r.isAtEnd {
                mirror = try r.bool()
                mirrorStatus = try r.string()
            }
            if !r.isAtEnd {
                mirrorRegion = try NormRect.decode(from: &r)
            }
            return .sessionConfig(SessionConfigMessage(
                mode: mode, profileName: profileName, displayName: displayName,
                inputRect: rect, showInputRect: showRect, leftHanded: leftHanded,
                toolbarVisible: toolbarVisible, toolbar: items,
                cursorLocked: locked, precisionMode: precision,
                palmRejection: palm, eraserActive: eraser,
                macCanPostEvents: canPost, macRTTms: rtt,
                mirrorActive: mirror, mirrorStatus: mirrorStatus, mirrorRegion: mirrorRegion))

        case .penBatch:
            let n = Int(try r.u16())
            guard r.remaining >= n * PenSample.encodedSize else { throw CodecError.truncated }
            var samples: [PenSample] = []
            samples.reserveCapacity(n)
            for _ in 0..<n { samples.append(try PenSample.decode(from: &r)) }
            return .penBatch(samples)

        case .gesture:
            guard let kind = GestureKind(rawValue: try r.u8()) else {
                throw CodecError.invalidValue("gesto")
            }
            return .gesture(GestureMessage(kind: kind, dx: try r.f32(), dy: try r.f32(),
                                           scale: try r.f32(), fingers: try r.u8()))

        case .button:
            return .button(ButtonMessage(buttonID: try r.u16(), pressed: try r.bool()))

        case .pencilGesture:
            guard let kind = PencilGestureKind(rawValue: try r.u8()),
                  let phase = GesturePhase(rawValue: try r.u8()) else {
                throw CodecError.invalidValue("gesto pencil")
            }
            return .pencilGesture(PencilGestureMessage(kind: kind, phase: phase))

        case .control:
            guard let cmd = ControlCommand(rawValue: try r.u8()) else {
                throw CodecError.invalidValue("comando")
            }
            return .control(ControlMessage(command: cmd, value: try r.i32()))

        case .ping:
            return .ping(PingMessage(id: try r.u32(), sentAt: try r.f64()))

        case .pong:
            return .pong(PongMessage(id: try r.u32(), sentAt: try r.f64(), peerTime: try r.f64()))

        case .pairingKey:
            return .pairingKey(PairingKeyMessage(macID: try r.string(), macName: try r.string(),
                                                 key: try r.blob()))

        case .deviceUpdate:
            return .deviceUpdate(DeviceUpdateMessage(capabilities: DeviceCapabilities(rawValue: try r.u16()),
                                                     surfaceWidth: try r.f32(), surfaceHeight: try r.f32()))

        case .bye:
            return .bye(try r.string())

        case .videoFrame:
            let id = try r.u32()
            let time = try r.f64()
            let width = try r.u16()
            let height = try r.u16()
            let format = try r.u8()
            let data = try r.blob()
            let region = r.isAtEnd ? NormRect.full : try NormRect.decode(from: &r)
            return .videoFrame(VideoFrameMessage(frameID: id, captureTime: time, width: width,
                                                 height: height, format: format, data: data, region: region))

        case .frameAck:
            return .frameAck(try r.u32())
        }
    }
}

// MARK: - Framing

/// Framing su flusso TCP: [u32 LE lunghezza = 1 + payload][u8 tipo][payload].
public enum Framing {
    public static func frame(type: UInt8, payload: Data) -> Data {
        var w = ByteWriter(capacity: payload.count + 5)
        w.u32(UInt32(payload.count + 1))
        w.u8(type)
        w.raw(payload)
        return w.data
    }
}

/// Ricostruisce i frame da un flusso di byte arbitrariamente frammentato.
public struct FrameDecoder {
    private var buffer = Data()
    private var readOffset = 0
    public let maxFrameBytes: Int

    public init(maxFrameBytes: Int = TabletWire.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    public var bufferedBytes: Int { buffer.count - readOffset }

    public mutating func append(_ data: Data) {
        // Compatta il buffer quando la parte già letta è grande.
        if readOffset > 0 && readOffset >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + readOffset)
            readOffset = 0
        }
        buffer.append(data)
    }

    /// Restituisce il prossimo frame completo, oppure nil se servono altri byte.
    public mutating func nextFrame() throws -> (type: UInt8, payload: Data)? {
        let available = buffer.count - readOffset
        guard available >= 5 else { return nil }
        let base = buffer.startIndex + readOffset
        var length32: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(buffer[base + i])
            length32 |= byte << UInt32(8 * i)
        }
        let length = Int(length32)
        guard length >= 1 else { throw CodecError.invalidValue("lunghezza frame 0") }
        guard length <= maxFrameBytes else { throw CodecError.frameTooLarge(length) }
        guard available >= 4 + length else { return nil }
        let type = buffer[base + 4]
        let payload = Data(buffer[(base + 5) ..< (base + 4 + length)])
        readOffset += 4 + length
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        return (type, payload)
    }

    /// Decodifica tutti i messaggi disponibili.
    public mutating func drainMessages() throws -> [TabletMessage] {
        var out: [TabletMessage] = []
        while let f = try nextFrame() {
            out.append(try TabletMessage.decode(type: f.type, payload: f.payload))
        }
        return out
    }
}
