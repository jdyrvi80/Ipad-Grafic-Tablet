//
//  FDTransport.swift
//  iPad Graphic Tablet — Mac
//
//  Trasporto su file descriptor POSIX: è il socket verso usbmuxd che,
//  dopo il comando "Connect", diventa un tunnel TCP trasparente verso
//  la porta 47820 dell'iPad attraverso il cavo USB.
//

import Foundation
import Darwin

final class FDTransport: ByteTransport {
    private let fd: Int32
    private let queue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "tablet.usb.write", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private let stateLock = NSLock()
    private var _closed = false
    private let pending = PendingCounter()   // definito in TabletLink/ByteTransport.swift
    let label: String

    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(fd: Int32, queue: DispatchQueue, label: String) {
        self.fd = fd
        self.queue = queue
        self.label = label
    }

    var pendingBytes: Int { pending.current }
    var peerDescription: String { label }

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _closed
    }

    func start() {
        // Lettura non bloccante guidata da un DispatchSource.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        let fd = self.fd
        let writeQueue = self.writeQueue
        source.setCancelHandler {
            // La chiusura passa dalla coda di scrittura: nessuna write in corso su un fd chiuso.
            writeQueue.async { Darwin.close(fd) }
        }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onReceive?(Data(buffer[0..<n]))
                if isClosed { return }
                if n < buffer.count { return }   // probabilmente svuotato
                continue
            }
            if n == 0 {
                finish(nil)                       // EOF: l'iPad ha chiuso o il cavo è stato scollegato
                return
            }
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { return }
            finish(POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO))
            return
        }
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        let count = data.count
        pending.add(count)
        writeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.pending.add(-count) }
            if self.isClosed { return }
            var failed = false
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(self.fd, base + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    let err = errno
                    if n < 0 && (err == EAGAIN || err == EWOULDBLOCK || err == EINTR) {
                        if self.isClosed { return }
                        var p = pollfd(fd: self.fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, 100)
                        continue
                    }
                    failed = true
                    return
                }
            }
            if failed {
                self.queue.async { self.finish(POSIXError(.EPIPE)) }
            }
        }
    }

    func close() {
        finish(nil)
    }

    private func finish(_ error: Error?) {
        stateLock.lock()
        if _closed { stateLock.unlock(); return }
        _closed = true
        stateLock.unlock()
        shutdown(fd, SHUT_RDWR)
        readSource?.cancel()
        readSource = nil
        let handler = onClose
        onClose = nil
        onReceive = nil
        if let handler {
            queue.async { handler(error) }
        }
    }
}
