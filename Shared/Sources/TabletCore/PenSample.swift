//
//  PenSample.swift
//  TabletCore
//
//  Un campione della Apple Pencil, così come rilevato da UIKit sull'iPad.
//  Codifica fissa da 32 byte: a 240 Hz sono ~7,7 KB/s, trascurabili
//  sia via USB sia via Wi-Fi.
//

import Foundation

/// Costanti di rete condivise tra Mac e iPad.
public enum TabletWire {
    /// Versione del protocollo binario. Incrementare a ogni modifica incompatibile.
    public static let protocolVersion: UInt16 = 1
    /// Porta TCP su cui l'app iPad ascolta in loopback: il Mac la raggiunge
    /// attraverso il tunnel USB di usbmuxd.
    public static let usbPort: UInt16 = 47820
    /// Porta TCP del Mac per le sessioni Wi-Fi (TLS-PSK con chiave di associazione).
    public static let wifiPort: UInt16 = 47821
    /// Porta TCP del Mac per l'associazione Wi-Fi tramite PIN a 6 cifre.
    public static let pairingPort: UInt16 = 47822
    /// Servizi Bonjour pubblicati dal Mac.
    public static let bonjourService = "_ipadtablet._tcp"
    public static let bonjourPairingService = "_ipadtablet-pair._tcp"
    /// Limite di sicurezza per un singolo frame (comprende i fotogrammi JPEG dello schermo).
    public static let maxFrameBytes = 16 * 1024 * 1024
    /// Identità TLS-PSK (non segreta).
    public static let pskIdentity = "ipad-graphic-tablet/v1"
}

/// Stato del campione.
public struct PenFlags: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// La punta tocca lo schermo.
    public static let contact = PenFlags(rawValue: 1 << 0)
    /// La penna è sospesa sopra lo schermo (hover, solo hardware compatibile).
    public static let hovering = PenFlags(rawValue: 1 << 1)
    /// Primo campione di un tratto (touchesBegan).
    public static let strokeBegan = PenFlags(rawValue: 1 << 2)
    /// Ultimo campione di un tratto (touchesEnded).
    public static let strokeEnded = PenFlags(rawValue: 1 << 3)
    /// Tratto annullato dal sistema (touchesCancelled).
    public static let cancelled = PenFlags(rawValue: 1 << 4)
    /// Campione predetto da UIKit (non usato dal Mac di default).
    public static let predicted = PenFlags(rawValue: 1 << 5)
    /// La pressione è una stima che UIKit potrebbe correggere più tardi.
    public static let estimatedPressure = PenFlags(rawValue: 1 << 6)
    /// La penna è uscita dal raggio di rilevamento (fine hover).
    public static let proximityOut = PenFlags(rawValue: 1 << 7)
}

/// Campione Apple Pencil normalizzato.
public struct PenSample: Equatable {
    /// Numero progressivo assegnato dall'iPad al momento dell'invio.
    public var sequence: UInt32
    /// Istante del campione in secondi (UITouch.timestamp, orologio dell'iPad).
    public var timestamp: Double
    /// Posizione normalizzata 0…1 sulla superficie dell'iPad (orientamento corrente, già calibrata).
    public var x: Float
    public var y: Float
    /// Pressione normalizzata 0…1 (force / maximumPossibleForce). Grezza: la curva è applicata sul Mac.
    public var pressure: Float
    /// Altitudine in radianti: 0 = penna parallela allo schermo, π/2 = perpendicolare.
    public var altitude: Float
    /// Azimut in radianti 0…2π nel sistema della vista (0 = asse +x, senso orario).
    public var azimuth: Float
    /// Rotazione sull'asse (barrel roll) in radianti, solo Apple Pencil Pro. 0 se non disponibile.
    public var roll: Float
    /// Distanza normalizzata in hover (zOffset 0…1). 0 a contatto.
    public var hoverDistance: Float
    public var flags: PenFlags

    public static let encodedSize = 32

    public init(sequence: UInt32 = 0, timestamp: Double, x: Float, y: Float,
                pressure: Float, altitude: Float, azimuth: Float,
                roll: Float = 0, hoverDistance: Float = 0, flags: PenFlags) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.pressure = pressure
        self.altitude = altitude
        self.azimuth = azimuth
        self.roll = roll
        self.hoverDistance = hoverDistance
        self.flags = flags
    }

    // Layout (32 byte, little-endian):
    //  0  u32  sequence
    //  4  f64  timestamp
    // 12  f32  x
    // 16  f32  y
    // 20  u16  pressure  (0…1)
    // 22  u16  altitude  (0…π/2)
    // 24  u16  azimuth   (0…2π)
    // 26  u16  roll      (0…2π)
    // 28  u16  hover     (0…1)
    // 30  u8   flags
    // 31  u8   riservato
    public func encode(into w: inout ByteWriter) {
        w.u32(sequence)
        w.f64(timestamp)
        w.f32(x)
        w.f32(y)
        w.u16(Quantize.unit16(pressure))
        w.u16(Quantize.angle16(min(max(altitude, 0), .pi / 2), max: .pi / 2))
        w.u16(Quantize.angle16(Quantize.wrapAngle(azimuth), max: .pi * 2))
        w.u16(Quantize.angle16(Quantize.wrapAngle(roll), max: .pi * 2))
        w.u16(Quantize.unit16(hoverDistance))
        w.u8(flags.rawValue)
        w.u8(0)
    }

    public static func decode(from r: inout ByteReader) throws -> PenSample {
        let seq = try r.u32()
        let ts = try r.f64()
        let x = try r.f32()
        let y = try r.f32()
        let p = Quantize.fromUnit16(try r.u16())
        let alt = Quantize.fromAngle16(try r.u16(), max: .pi / 2)
        let az = Quantize.fromAngle16(try r.u16(), max: .pi * 2)
        let roll = Quantize.fromAngle16(try r.u16(), max: .pi * 2)
        let hover = Quantize.fromUnit16(try r.u16())
        let flags = PenFlags(rawValue: try r.u8())
        _ = try r.u8()
        guard x.isFinite, y.isFinite, ts.isFinite else {
            throw CodecError.invalidValue("coordinate non finite")
        }
        return PenSample(sequence: seq, timestamp: ts, x: x, y: y, pressure: p,
                         altitude: alt, azimuth: az, roll: roll,
                         hoverDistance: hover, flags: flags)
    }
}
