//
//  TabletLog.swift
//  TabletLink
//
//  Log su Console di sistema (os.Logger) + ultime righe in memoria
//  per la sezione Diagnostica dell'interfaccia. Nessun log su disco.
//

import Foundation
import os

public final class TabletLog {
    public static let shared = TabletLog()

    private let logger = Logger(subsystem: "com.jodyriva.ipadtablet", category: "tablet")
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 300
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Notifica (sul main thread) quando arriva una riga nuova.
    public var onLine: ((String) -> Void)?

    public func info(_ message: String) { append("ℹ︎ " + message); logger.info("\(message, privacy: .public)") }
    public func warn(_ message: String) { append("⚠︎ " + message); logger.warning("\(message, privacy: .public)") }
    public func error(_ message: String) { append("✖︎ " + message); logger.error("\(message, privacy: .public)") }

    public var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    private func append(_ text: String) {
        lock.lock()
        let line = "\(formatter.string(from: Date()))  \(text)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
        if let cb = onLine {
            DispatchQueue.main.async { cb(line) }
        }
    }
}

/// Scorciatoia globale (nome volutamente diverso da `log`, la funzione matematica).
public let tlog = TabletLog.shared
