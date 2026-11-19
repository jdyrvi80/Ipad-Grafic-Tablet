//
//  ByteCoding.swift
//  TabletCore — modulo condiviso Mac/iPad (solo Foundation)
//
//  Lettura/scrittura binaria little-endian, senza dipendenze.
//  Tutti i messaggi del protocollo passano da qui: niente JSON,
//  niente Codable sul canale dati, per avere pacchetti piccoli e
//  una codifica deterministica a costo quasi nullo.
//

import Foundation

/// Errori di codifica/decodifica del protocollo.
public enum CodecError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalidValue(String)
    case unknownMessage(UInt8)
    case frameTooLarge(Int)
    case versionMismatch(UInt16)

    public var description: String {
        switch self {
        case .truncated: return "Pacchetto troncato"
        case .invalidValue(let s): return "Valore non valido: \(s)"
        case .unknownMessage(let t): return "Tipo di messaggio sconosciuto: \(t)"
        case .frameTooLarge(let n): return "Frame troppo grande: \(n) byte"
        case .versionMismatch(let v): return "Versione di protocollo incompatibile: \(v)"
        }
    }
}

/// Scrittore binario little-endian.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    @inline(__always)
    private mutating func writeLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { writeLE(v) }
    public mutating func u32(_ v: UInt32) { writeLE(v) }
    public mutating func u64(_ v: UInt64) { writeLE(v) }
    public mutating func i32(_ v: Int32) { writeLE(UInt32(bitPattern: v)) }
    public mutating func f32(_ v: Float) { writeLE(v.bitPattern) }
    public mutating func f64(_ v: Double) { writeLE(v.bitPattern) }

    /// Stringa UTF-8 con prefisso di lunghezza a 16 bit (troncata a 65535 byte).
    public mutating func string(_ s: String) {
        let bytes = Array(s.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// Blocco di byte con prefisso di lunghezza a 32 bit.
    public mutating func blob(_ d: Data) {
        u32(UInt32(d.count))
        data.append(d)
    }

    /// Byte grezzi, senza prefisso.
    public mutating func raw(_ d: Data) { data.append(d) }
}

/// Lettore binario little-endian con controllo dei limiti.
public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { remaining == 0 }

    @inline(__always)
    private mutating func readLE<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw CodecError.truncated }
        var value: T = 0
        for i in 0..<size {
            value |= T(data[offset + i]) << (8 * i)
        }
        offset += size
        return value
    }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw CodecError.truncated }
        let v = data[offset]
        offset += 1
        return v
    }

    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 { try readLE(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try readLE(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try readLE(UInt64.self) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try readLE(UInt32.self)) }
    public mutating func f32() throws -> Float { Float(bitPattern: try readLE(UInt32.self)) }
    public mutating func f64() throws -> Double { Double(bitPattern: try readLE(UInt64.self)) }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw CodecError.truncated }
        let slice = data[offset ..< offset + count]
        offset += count
        return Data(slice)
    }

    public mutating func string() throws -> String {
        let n = Int(try u16())
        let d = try bytes(n)
        guard let s = String(data: d, encoding: .utf8) else {
            throw CodecError.invalidValue("stringa UTF-8")
        }
        return s
    }

    public mutating func blob() throws -> Data {
        let n = Int(try u32())
        return try bytes(n)
    }
}

// MARK: - Quantizzazione

/// Conversioni tra valori in virgola mobile e interi a 16 bit:
/// riducono la dimensione dei campioni senza perdita percepibile
/// (65535 livelli, oltre 15 volte la risoluzione della pressione di una Wacom Pro Pen 3).
public enum Quantize {
    @inline(__always)
    public static func unit16(_ v: Float) -> UInt16 {
        let c = min(max(v, 0), 1)
        return UInt16((c * 65535).rounded())
    }

    @inline(__always)
    public static func fromUnit16(_ v: UInt16) -> Float {
        Float(v) / 65535
    }

    /// Angolo in [0, maxAngle] → UInt16.
    @inline(__always)
    public static func angle16(_ v: Float, max maxAngle: Float) -> UInt16 {
        unit16(v / maxAngle)
    }

    @inline(__always)
    public static func fromAngle16(_ v: UInt16, max maxAngle: Float) -> Float {
        fromUnit16(v) * maxAngle
    }

    /// Normalizza un angolo in [0, 2π).
    @inline(__always)
    public static func wrapAngle(_ a: Float) -> Float {
        let twoPi = Float.pi * 2
        var r = a.truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        return r
    }
}
