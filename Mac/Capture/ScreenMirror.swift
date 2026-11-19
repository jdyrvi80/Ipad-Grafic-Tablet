//
//  ScreenMirror.swift
//  iPad Graphic Tablet — Mac
//
//  Modalità Display: cattura del monitor (o di un'area) con ScreenCaptureKit e
//  invio all'iPad come fotogrammi JPEG.
//
//  Perché JPEG e non H.264: Safari su una pagina http non ha il decoder video
//  WebCodecs (richiede https). I JPEG si decodificano ovunque e, con il controllo
//  di flusso a conferme (ack), la frequenza si adatta da sola alla rete:
//  al massimo 2 fotogrammi "in volo", l'ultimo fotogramma non inviato viene
//  tenuto da parte e spedito appena arriva una conferma, quindi l'immagine
//  sull'iPad è sempre aggiornata anche quando lo schermo smette di cambiare.
//
//  Nitidezza da fermo: quando lo schermo smette di cambiare per un attimo, si invia
//  una versione a piena risoluzione Retina dell'iPad e qualità alta (foto singola con
//  SCScreenshotManager se lo stream è a risoluzione ridotta). Il movimento resta fluido,
//  l'immagine ferma è nitida.
//
//  Permesso richiesto: Registrazione schermo (macOS lo chiede alla prima cattura;
//  dopo averlo concesso l'app va riaperta).
//

import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import ImageIO

/// Parametri della cattura.
struct MirrorRequest: Equatable {
    var displayID: CGDirectDisplayID
    /// Area da catturare, in punti, relativa all'angolo in alto a sinistra del monitor.
    var sourceRect: CGRect
    /// Dimensione dei fotogrammi in pixel.
    var pixelWidth: Int
    var pixelHeight: Int
    var maxFPS: Int
    var quality: Double
    /// La stessa area normalizzata sul monitor: viaggia con ogni fotogramma.
    var region: NormRect = .full
    /// Dimensioni a piena risoluzione Retina dell'iPad (versione nitida da fermo).
    var sharpWidth: Int = 0
    var sharpHeight: Int = 0
    var sharpenWhenIdle: Bool = true
}

/// Statistiche per l'interfaccia.
struct MirrorStats: Equatable {
    var running = false
    var fps: Double = 0
    var averageKB: Double = 0
    var pixelWidth = 0
    var pixelHeight = 0
    /// Ultima versione nitida inviata (0 = nessuna).
    var sharpWidth = 0
    var sharpHeight = 0
    var message = ""
}

final class ScreenMirror: NSObject, SCStreamOutput, SCStreamDelegate {

    private let captureQueue = DispatchQueue(label: "tablet.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Stato (solo sulla captureQueue)
    private var stream: SCStream?
    private var current: MirrorRequest?
    private var inFlight = 0
    private var pending: (buffer: CVPixelBuffer, region: NormRect)?
    /// Area effettivamente catturata dalla configurazione attiva (aggiornata quando macOS la applica).
    private var appliedRegion = NormRect.full
    private var frameID: UInt32 = 0
    private var lastSend: Double = 0
    private var quality: Double = 0.6
    private var sentTimes: [Double] = []
    private var sentSizes: [Int] = []
    private var starting = false

    // Nitidezza da fermo
    private static let sharpDelay: Double = 0.25
    private static let sharpQuality: Double = 0.95
    private var filter: SCContentFilter?
    private var lastBuffer: CVPixelBuffer?
    private var lastBufferRegion = NormRect.full
    private var generation = 0
    private var sharpWork: DispatchWorkItem?
    private var sharpDone = false
    private var sharpWanted = false
    private var lastSharpWidth = 0
    private var lastSharpHeight = 0

    /// Fotogramma pronto (chiamato sulla captureQueue).
    var onFrame: ((VideoFrameMessage) -> Void)?
    /// Aggiornamenti di stato (sul main thread).
    var onStats: ((MirrorStats) -> Void)?

    private var statsTimer: DispatchSourceTimer?

    override init() {
        super.init()
        let t = DispatchSource.makeTimerSource(queue: captureQueue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.publishStats(message: nil) }
        statsTimer = t
        t.resume()
    }

    // MARK: - Avvio / aggiornamento / arresto

    /// Applica la richiesta: avvia, aggiorna al volo o non fa nulla se invariata.
    func apply(_ request: MirrorRequest?) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard let request else {
                self.stopOnQueue()
                return
            }
            if request == self.current && (self.stream != nil || self.starting) { return }
            self.quality = request.quality
            self.invalidateSharp()
            if let stream = self.stream, let old = self.current, old.displayID == request.displayID {
                // Stesso monitor: si aggiorna solo la configurazione (area, dimensioni, fps).
                self.current = request
                let config = self.configuration(for: request)
                stream.updateConfiguration(config) { [weak self] error in
                    guard let self else { return }
                    self.captureQueue.async {
                        if let error {
                            tlog.error("Display: aggiornamento cattura fallito: \(error.localizedDescription)")
                            self.restart(request)
                        } else {
                            // Da qui in poi i fotogrammi contengono la nuova area.
                            self.appliedRegion = request.region
                        }
                    }
                }
                // Il controllo di flusso resta valido: zoom e spostamento non devono riempire la rete.
                return
            }
            self.restart(request)
        }
    }

    /// Conferma dall'iPad: il fotogramma è stato mostrato.
    func acknowledge(_ id: UInt32) {
        captureQueue.async {
            self.inFlight = max(0, self.inFlight - 1)
            if self.inFlight < 2, let next = self.pending {
                self.pending = nil
                self.send(next.buffer, region: next.region)
            }
            // La versione nitida aspettava che la rete si liberasse.
            if self.inFlight < 2, self.pending == nil, self.sharpWanted {
                self.sharpenIfIdle(self.generation)
            }
        }
    }

    private func resetFlow() {
        inFlight = 0
        pending = nil
    }

    private func stopOnQueue() {
        current = nil
        resetFlow()
        invalidateSharp()
        lastBuffer = nil
        filter = nil
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { error in
            if let error { tlog.warn("Display: arresto cattura: \(error.localizedDescription)") }
        }
        tlog.info("Display: cattura dello schermo fermata")
        publishStats(message: "")
    }

    private func restart(_ request: MirrorRequest) {
        if let old = stream {
            stream = nil
            old.stopCapture { _ in }
        }
        current = request
        resetFlow()
        invalidateSharp()
        lastBuffer = nil
        filter = nil
        starting = true
        Task { [weak self] in
            await self?.startCapture(request)
        }
    }

    private func startCapture(_ request: MirrorRequest) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
                finishStart(nil, filter: nil, request: request, message: "Monitor non trovato")
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration(for: request), delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            finishStart(stream, filter: filter, request: request, message: "")
            tlog.info("Display: cattura avviata \(request.pixelWidth)×\(request.pixelHeight) @ \(request.maxFPS) fps")
        } catch {
            let message: String
            if CGPreflightScreenCaptureAccess() {
                message = "Cattura non avviata: \(error.localizedDescription)"
            } else {
                message = "Serve il permesso Registrazione schermo sul Mac (poi riapri l'app)"
            }
            tlog.error("Display: \(message)")
            finishStart(nil, filter: nil, request: request, message: message)
        }
    }

    private func finishStart(_ stream: SCStream?, filter: SCContentFilter?, request: MirrorRequest, message: String) {
        captureQueue.async {
            self.starting = false
            guard self.current == request else {
                // Nel frattempo la richiesta è cambiata o la cattura è stata fermata.
                stream?.stopCapture { _ in }
                return
            }
            self.stream = stream
            self.filter = filter
            self.appliedRegion = request.region
            self.publishStats(message: message)
        }
    }

    private func configuration(for request: MirrorRequest) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(request.pixelWidth, 16)
        config.height = max(request.pixelHeight, 16)
        config.sourceRect = request.sourceRect
        let fps = Int32(max(5, min(request.maxFPS, 60)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 5
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, stream === self.stream else { return }
        // Solo fotogrammi con contenuto nuovo (gli "idle" non cambiano nulla).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let now = MonotonicClock.now()
        if inFlight >= 2 && now - lastSend > 1.5 {
            // Nessuna conferma da 1,5 s (pagina in background?): si riparte.
            inFlight = 0
        }
        if inFlight >= 2 {
            pending = (pixelBuffer, appliedRegion)      // si tiene solo il più recente
        } else {
            send(pixelBuffer, region: appliedRegion)
        }
        noteNewFrame(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureQueue.async {
            guard stream === self.stream else { return }
            self.stream = nil
            tlog.error("Display: la cattura si è interrotta: \(error.localizedDescription)")
            self.publishStats(message: "Cattura interrotta: \(error.localizedDescription)")
        }
    }

    // MARK: - Codifica e invio

    private func encode(_ image: CIImage, quality q: Double) -> Data? {
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [key: q]
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    private func send(_ pixelBuffer: CVPixelBuffer, region: NormRect) {
        guard let jpeg = encode(CIImage(cvPixelBuffer: pixelBuffer), quality: quality) else { return }
        deliver(jpeg, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                region: region)
    }

    private func deliver(_ jpeg: Data, width pixelWidth: Int, height pixelHeight: Int, region: NormRect) {
        frameID &+= 1
        inFlight += 1
        let now = MonotonicClock.now()
        lastSend = now
        sentTimes.append(now)
        sentSizes.append(jpeg.count)
        if sentTimes.count > 120 {
            sentTimes.removeFirst(sentTimes.count - 120)
            sentSizes.removeFirst(sentSizes.count - 120)
        }

        let width = UInt16(clamping: pixelWidth)
        let height = UInt16(clamping: pixelHeight)
        let frame = VideoFrameMessage(frameID: frameID, captureTime: now, width: width, height: height,
                                      data: jpeg, region: region)
        onFrame?(frame)
    }

    // MARK: - Nitidezza da fermo

    private func invalidateSharp() {
        generation &+= 1
        sharpWork?.cancel()
        sharpWork = nil
        sharpDone = false
        sharpWanted = false
    }

    /// Nuovo contenuto sullo schermo: la versione nitida si prepara solo se poi resta fermo.
    private func noteNewFrame(_ buffer: CVPixelBuffer) {
        invalidateSharp()
        lastBuffer = buffer
        lastBufferRegion = appliedRegion
        guard let request = current, request.sharpenWhenIdle else { return }
        let gen = generation
        let work = DispatchWorkItem { [weak self] in self?.sharpenIfIdle(gen) }
        sharpWork = work
        captureQueue.asyncAfter(deadline: .now() + ScreenMirror.sharpDelay, execute: work)
    }

    private func sharpenIfIdle(_ gen: Int) {
        guard gen == generation, !sharpDone, let request = current, request.sharpenWhenIdle else { return }
        // Prima partono i fotogrammi normali in attesa: la versione nitida arriva per ultima.
        if inFlight >= 2 || pending != nil {
            sharpWanted = true
            return
        }
        sharpDone = true
        sharpWanted = false

        let biggerNeeded: Bool = request.sharpWidth > request.pixelWidth + 8 || request.sharpHeight > request.pixelHeight + 8
        if !biggerNeeded, let buffer = lastBuffer {
            // Lo stream è già a piena risoluzione: basta ricodificare con qualità alta.
            sendSharp(CIImage(cvPixelBuffer: buffer), region: lastBufferRegion)
            return
        }
        guard let filter, request.sharpWidth > 0, request.sharpHeight > 0 else { return }
        let config = SCStreamConfiguration()
        config.width = request.sharpWidth
        config.height = request.sharpHeight
        config.sourceRect = request.sourceRect
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        let region = request.region
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, error in
            guard let self else { return }
            self.captureQueue.async {
                // Se nel frattempo lo schermo è cambiato, la foto è già vecchia: si scarta.
                guard gen == self.generation else { return }
                guard let image else {
                    if let error { tlog.warn("Display: versione nitida non riuscita: \(error.localizedDescription)") }
                    return
                }
                if self.inFlight >= 2 {
                    self.sharpDone = false
                    self.sharpWanted = true
                    return
                }
                self.sendSharp(CIImage(cgImage: image), region: region)
            }
        }
    }

    private func sendSharp(_ image: CIImage, region: NormRect) {
        guard let jpeg = encode(image, quality: ScreenMirror.sharpQuality) else { return }
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)
        lastSharpWidth = w
        lastSharpHeight = h
        deliver(jpeg, width: w, height: h, region: region)
    }

    private var lastMessage = ""

    private func publishStats(message: String?) {
        if let message { lastMessage = message }
        var stats = MirrorStats()
        stats.running = stream != nil
        stats.message = lastMessage
        if let c = current {
            stats.pixelWidth = c.pixelWidth
            stats.pixelHeight = c.pixelHeight
        }
        stats.sharpWidth = lastSharpWidth
        stats.sharpHeight = lastSharpHeight
        let now = MonotonicClock.now()
        var recentCount = 0
        var recentBytes = 0
        for (i, t) in sentTimes.enumerated() where now - t <= 1.0 {
            recentCount += 1
            recentBytes += sentSizes[i]
        }
        stats.fps = Double(recentCount)
        stats.averageKB = recentCount > 0 ? Double(recentBytes) / Double(recentCount) / 1024 : 0
        let cb = onStats
        DispatchQueue.main.async { cb?(stats) }
    }
}
