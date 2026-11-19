//
//  LatencyStats.swift
//  TabletCore
//
//  Statistiche di latenza (RTT) e stima dell'offset tra gli orologi
//  di iPad e Mac, usata per calcolare la latenza penna → cursore.
//

import Foundation

/// Orologio monotono in secondi, compatibile con UITouch.timestamp
/// (entrambi basati sull'uptime di sistema).
public enum MonotonicClock {
    @inline(__always)
    public static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

public struct LatencySummary: Equatable {
    public var count: Int = 0
    public var lastMs: Double = 0
    public var minMs: Double = 0
    public var avgMs: Double = 0
    public var p95Ms: Double = 0
    public var maxMs: Double = 0
    public var jitterMs: Double = 0
    public init() {}
}

public struct LatencyStats {
    private var samples: [Double] = []   // RTT in secondi
    private let capacity: Int
    /// Offset stimato: orologioPeer − orologioLocale (secondi).
    public private(set) var clockOffset: Double?
    private var bestRTTForOffset: Double = .infinity

    public init(capacity: Int = 200) {
        self.capacity = capacity
        samples.reserveCapacity(capacity)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        clockOffset = nil
        bestRTTForOffset = .infinity
    }

    /// Registra un pong ricevuto.
    /// - Parameters:
    ///   - sentAt: istante locale di invio del ping
    ///   - receivedAt: istante locale di ricezione del pong
    ///   - peerTime: istante in cui il peer ha ricevuto il ping (suo orologio)
    public mutating func record(sentAt: Double, receivedAt: Double, peerTime: Double) {
        let rtt = receivedAt - sentAt
        guard rtt >= 0, rtt < 10 else { return }
        if samples.count == capacity { samples.removeFirst() }
        samples.append(rtt)
        // Stima stile NTP: il peer ha ricevuto il ping a metà del RTT.
        // Si tiene la stima del campione con RTT più basso (meno rumore),
        // lasciandola "invecchiare" lentamente per seguire la deriva.
        let offset = peerTime - (sentAt + rtt / 2)
        bestRTTForOffset *= 1.02
        if rtt <= bestRTTForOffset || clockOffset == nil {
            bestRTTForOffset = rtt
            clockOffset = offset
        }
    }

    /// Converte un istante del peer nell'orologio locale (se l'offset è noto).
    public func localTime(fromPeer t: Double) -> Double? {
        guard let off = clockOffset else { return nil }
        return t - off
    }

    public var summary: LatencySummary {
        var s = LatencySummary()
        guard !samples.isEmpty else { return s }
        let ms = samples.map { $0 * 1000 }
        let sorted = ms.sorted()
        s.count = ms.count
        s.lastMs = ms.last ?? 0
        s.minMs = sorted.first ?? 0
        s.maxMs = sorted.last ?? 0
        s.avgMs = ms.reduce(0, +) / Double(ms.count)
        let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        s.p95Ms = sorted[idx]
        if ms.count > 1 {
            var acc = 0.0
            for i in 1..<ms.count { acc += abs(ms[i] - ms[i - 1]) }
            s.jitterMs = acc / Double(ms.count - 1)
        }
        return s
    }
}

/// Misura la frequenza di eventi in una finestra mobile di 1 secondo.
public struct RateMeter {
    private var stamps: [Double] = []
    public init() {}

    public mutating func tick(_ t: Double, count: Int = 1) {
        for _ in 0..<count { stamps.append(t) }
        let limit = t - 1.0
        if let firstValid = stamps.firstIndex(where: { $0 >= limit }), firstValid > 0 {
            stamps.removeFirst(firstValid)
        }
    }

    public func rate(at t: Double) -> Double {
        let limit = t - 1.0
        return Double(stamps.filter { $0 >= limit }.count)
    }
}
