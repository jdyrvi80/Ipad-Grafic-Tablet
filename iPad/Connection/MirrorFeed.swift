//
//  MirrorFeed.swift
//  iPad Graphic Tablet — iPad
//
//  Modalità Display: decodifica dei fotogrammi JPEG dello schermo del Mac.
//  Un solo fotogramma in decodifica e uno in attesa; i più vecchi vengono
//  scartati ma confermati comunque, così il Mac non si blocca.
//

import UIKit
import Combine

/// Fotogramma decodificato con l'area del monitor che contiene.
struct MirrorFrame {
    let image: UIImage
    let region: NormRect
}

final class MirrorFeed: ObservableObject {
    @Published private(set) var frame: MirrorFrame?

    private let decodeQueue = DispatchQueue(label: "pad.mirror.decode", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var pending: (frame: VideoFrameMessage, ack: (UInt32) -> Void)?

    /// Chiamabile da qualsiasi thread.
    func receive(_ frame: VideoFrameMessage, ack: @escaping (UInt32) -> Void) {
        lock.lock()
        if busy {
            let replaced = pending
            pending = (frame, ack)
            lock.unlock()
            if let replaced { replaced.ack(replaced.frame.frameID) }
            return
        }
        busy = true
        lock.unlock()
        decode(frame, ack: ack)
    }

    private func decode(_ frame: VideoFrameMessage, ack: @escaping (UInt32) -> Void) {
        decodeQueue.async { [weak self] in
            // preparingForDisplay decodifica subito, fuori dal main thread.
            let decoded = UIImage(data: frame.data)?.preparingForDisplay()
            DispatchQueue.main.async {
                guard let self else { return }
                if let decoded { self.frame = MirrorFrame(image: decoded, region: frame.region) }
                ack(frame.frameID)
                self.next()
            }
        }
    }

    private func next() {
        lock.lock()
        if let p = pending {
            pending = nil
            lock.unlock()
            decode(p.frame, ack: p.ack)
        } else {
            busy = false
            lock.unlock()
        }
    }

    func clear() {
        DispatchQueue.main.async { self.frame = nil }
    }
}
