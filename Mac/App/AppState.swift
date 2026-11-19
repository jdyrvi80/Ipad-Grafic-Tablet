//
//  AppState.swift
//  iPad Graphic Tablet — Mac
//
//  Stato dell'app osservato dall'interfaccia SwiftUI (sempre sul main thread).
//  Collega profili, motore di input e connessioni.
//

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

final class AppState: ObservableObject {
    static let shared = AppState()

    let engine: TabletEngine
    let connections: ConnectionManager
    let store: ProfileStore
    /// Cattura dello schermo per la modalità Display.
    let mirror = ScreenMirror()

    @Published private(set) var profiles: [TabletProfile]
    @Published private(set) var activeProfileID: UUID
    @Published var connection = ConnectionSnapshot()
    @Published var stats = EngineStats()
    @Published var displays: [DisplayInfo] = []
    @Published var pairingPIN: String?
    @Published var pairingDeadline: Date?
    @Published var logLines: [String] = []
    @Published var permissionRequested = false
    @Published var mirrorStats = MirrorStats()
    private var screenPermissionRequested = false
    private var lastMirrorRequest: MirrorRequest?
    @Published var usbEnabled: Bool {
        didSet {
            UserDefaults.standard.set(usbEnabled, forKey: "usbEnabled")
            connections.setUSB(enabled: usbEnabled)
        }
    }
    @Published var wifiEnabled: Bool {
        didSet {
            UserDefaults.standard.set(wifiEnabled, forKey: "wifiEnabled")
            connections.setWiFi(enabled: wifiEnabled)
        }
    }
    /// Pagina per Safari: l'iPad si collega digitando l'IP del Mac, senza installare app.
    @Published var webEnabled: Bool {
        didSet {
            UserDefaults.standard.set(webEnabled, forKey: "webEnabled")
            connections.setWeb(enabled: webEnabled)
        }
    }
    @Published private(set) var webCode: String

    private var saveWork: DispatchWorkItem?
    private var started = false

    private init() {
        let engine = TabletEngine()
        self.engine = engine
        self.connections = ConnectionManager(engine: engine)
        let store = ProfileStore()
        self.store = store
        let loaded = store.load()
        profiles = loaded
        let savedID = UserDefaults.standard.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:))
        activeProfileID = loaded.first(where: { $0.id == savedID })?.id ?? ProfilePresets.photoshop.id
        let defaults = UserDefaults.standard
        usbEnabled = defaults.object(forKey: "usbEnabled") as? Bool ?? true
        wifiEnabled = defaults.object(forKey: "wifiEnabled") as? Bool ?? true
        webEnabled = defaults.object(forKey: "webEnabled") as? Bool ?? true
        if let data = KeychainStore.load(account: "web-access-code"),
           let code = String(data: data, encoding: .utf8), code.count == 6 {
            webCode = code
        } else {
            let code = WebClientServer.newCode()
            KeychainStore.save(Data(code.utf8), account: "web-access-code")
            webCode = code
        }
    }

    // MARK: - Avvio

    func start() {
        guard !started else { return }
        started = true
        KeyboardLayoutResolver.shared.startObserving()
        refreshDisplays()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplays()
        }

        tlog.onLine = { [weak self] line in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 300 { self.logLines.removeFirst(self.logLines.count - 300) }
        }
        logLines = tlog.recent

        engine.onStats = { [weak self] s in
            guard let self, s != self.stats else { return }
            self.stats = s
        }
        engine.onRequest = { [weak self] r in self?.handle(r) }
        engine.onDisplayRegionChanged = { [weak self] id, region in self?.displayRegionChangedOnIPad(id, region) }

        connections.onSnapshot = { [weak self] snap in
            guard let self else { return }
            let mirrorRelevant = snap.phase != self.connection.phase
                || snap.capabilities != self.connection.capabilities
                || snap.surfaceSize != self.connection.surfaceSize
            self.connection = snap
            if !snap.pairingActive { self.pairingPIN = nil; self.pairingDeadline = nil }
            if mirrorRelevant { self.updateMirror() }
        }

        // Modalità Display: fotogrammi verso l'iPad e conferme di ritorno.
        let connections = self.connections
        let mirror = self.mirror
        mirror.onFrame = { frame in connections.sendVideoFrame(frame) }
        connections.onFrameAck = { id in mirror.acknowledge(id) }
        mirror.onStats = { [weak self] stats in
            guard let self else { return }
            let messageChanged = stats.message != self.mirrorStats.message
            if stats != self.mirrorStats { self.mirrorStats = stats }
            if messageChanged {
                self.engine.setMirrorStatus(stats.message)
                self.connections.sendConfig()
            }
        }
        connections.onControl = { [weak self] c in self?.handleControl(c) }

        connections.usbEnabled = usbEnabled
        connections.wifiEnabled = wifiEnabled
        connections.webEnabled = webEnabled
        connections.webCode = webCode
        pushProfile()
        connections.start()
        tlog.info("iPad Graphic Tablet avviato — backend input: \(engine.backendName)")
    }

    func refreshDisplays() {
        displays = DisplayManager.activeDisplays()
        lastMirrorRequest = nil      // i monitor sono cambiati: si ricalcola la cattura
        pushProfile()
    }

    // MARK: - Profili

    var activeProfile: TabletProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? ProfilePresets.generic
    }

    /// Modifica il profilo attivo (binding per l'interfaccia).
    func updateActiveProfile(_ change: (inout TabletProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        var p = profiles[index]
        change(&p)
        guard p != profiles[index] else { return }
        profiles[index] = p
        profileDidChange()
    }

    /// Binding a una proprietà del profilo attivo.
    func binding<T>(_ keyPath: WritableKeyPath<TabletProfile, T>) -> Binding<T> {
        Binding(
            get: { self.activeProfile[keyPath: keyPath] },
            set: { newValue in self.updateActiveProfile { $0[keyPath: keyPath] = newValue } })
    }

    func selectProfile(_ id: UUID) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: "activeProfileID")
        tlog.info("Profilo attivo: \(activeProfile.name)")
        pushProfile()
    }

    func nextProfile() {
        guard let i = profiles.firstIndex(where: { $0.id == activeProfileID }), !profiles.isEmpty else { return }
        selectProfile(profiles[(i + 1) % profiles.count].id)
    }

    func duplicateActiveProfile() {
        let copy = activeProfile.duplicated(named: activeProfile.name + " (copia)")
        profiles.append(copy)
        selectProfile(copy.id)
        scheduleSave()
    }

    func renameActiveProfile(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateActiveProfile { $0.name = trimmed }
    }

    func deleteProfile(_ id: UUID) {
        guard let p = profiles.first(where: { $0.id == id }), !p.isPreset, profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { selectProfile(profiles[0].id) }
        scheduleSave()
    }

    /// Riporta i profili preconfigurati ai valori di fabbrica (i profili personali restano).
    func resetPresets() {
        for preset in ProfilePresets.all {
            if let i = profiles.firstIndex(where: { $0.id == preset.id }) { profiles[i] = preset }
            else { profiles.append(preset) }
        }
        profileDidChange()
    }

    func exportProfiles() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Profili iPad Graphic Tablet.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(profiles, to: url) } catch { tlog.error("Esportazione fallita: \(error)") }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try store.importProfiles(from: url)
            for var p in imported {
                if let i = profiles.firstIndex(where: { $0.id == p.id }) {
                    profiles[i] = p
                } else {
                    p.isPreset = false
                    profiles.append(p)
                }
            }
            profileDidChange()
            tlog.info("Importati \(imported.count) profili")
        } catch {
            tlog.error("Importazione fallita: \(error)")
        }
    }

    private func profileDidChange() {
        pushProfile()
        scheduleSave()
    }

    /// Invia profilo e monitor al motore, poi la configurazione all'iPad.
    private func pushProfile() {
        engine.apply(profile: activeProfile, displays: displays)
        connections.sendConfig()
        updateMirror()
    }

    // MARK: - Modalità Display (schermo sull'iPad)

    /// Avvia, aggiorna o ferma la cattura in base a profilo, monitor e iPad collegato.
    func updateMirror() {
        let request = makeMirrorRequest()
        guard request != lastMirrorRequest else { return }
        lastMirrorRequest = request
        if request != nil && !CGPreflightScreenCaptureAccess() && !screenPermissionRequested {
            // Richiesta di sistema una sola volta per avvio; dopo averla concessa macOS chiede di riaprire l'app.
            screenPermissionRequested = true
            _ = CGRequestScreenCaptureAccess()
        }
        mirror.apply(request)
    }

    private func makeMirrorRequest() -> MirrorRequest? {
        let p = activeProfile
        guard p.mode == .display,
              connection.phase == .connected,
              connection.capabilities.contains(.videoDisplay),
              let display = DisplayManager.resolve(uuid: p.displayUUID, in: displays) else { return nil }

        let source = DisplayRegion.localRect(p.displayRegion.clamped(), displaySize: display.bounds.size)
        guard source.width >= 16, source.height >= 16 else { return nil }

        // Dimensione dell'immagine sull'iPad (letterbox dell'area nelle proporzioni dell'iPad).
        let surface = connection.surfaceSize
        guard surface.width > 0, surface.height > 0 else { return nil }
        let surfaceAspect: Double = Double(surface.width / surface.height)
        let regionAspect: Double = Double(source.width / source.height)
        let fit = InputArea.effectiveRect(activeArea: .full, rotatedAspect: surfaceAspect, targetAspect: regionAspect)
        let shownWidthPoints: Double = Double(fit.width) * Double(surface.width)
        let displayScale: Double = display.bounds.width > 0 ? Double(display.pixelWidth) / Double(display.bounds.width) : 2
        let sourcePixelWidth: Double = Double(source.width) * displayScale

        let resolution: Double = min(max(p.mirrorResolution, 0.3), 1)
        let normal = AppState.mirrorPixelSize(shownWidthPoints: shownWidthPoints, iPadScale: connection.screenScale,
                                              resolution: resolution, sourcePixelWidth: sourcePixelWidth,
                                              aspect: regionAspect)
        // Piena risoluzione Retina: usata per la versione nitida quando lo schermo è fermo.
        let sharp = AppState.mirrorPixelSize(shownWidthPoints: shownWidthPoints, iPadScale: connection.screenScale,
                                             resolution: 1, sourcePixelWidth: sourcePixelWidth,
                                             aspect: regionAspect)
        return MirrorRequest(displayID: display.id, sourceRect: source,
                             pixelWidth: normal.width, pixelHeight: normal.height,
                             maxFPS: p.mirrorMaxFPS, quality: min(max(p.mirrorQuality, 0.3), 1),
                             region: p.displayRegion.clamped(),
                             sharpWidth: sharp.width, sharpHeight: sharp.height,
                             sharpenWhenIdle: p.mirrorSharpenWhenIdle)
    }

    /// Pixel da inviare: frazione dei pixel Retina dell'iPad, mai oltre i pixel reali del monitor
    /// (ingrandire non aggiunge dettaglio) né oltre 4096 px sul lato lungo.
    static func mirrorPixelSize(shownWidthPoints: Double, iPadScale: Double, resolution: Double,
                                sourcePixelWidth: Double, aspect: Double) -> (width: Int, height: Int) {
        var pixelWidth: Double = shownWidthPoints * iPadScale * resolution
        pixelWidth = min(pixelWidth, sourcePixelWidth)
        var pixelHeight: Double = pixelWidth / max(aspect, 0.01)
        let longest: Double = max(pixelWidth, pixelHeight)
        if longest > 4096 {
            let k: Double = 4096 / longest
            pixelWidth *= k
            pixelHeight *= k
        }
        // Dimensioni pari: alcuni encoder/decoder lo preferiscono.
        let w = max(16, Int(pixelWidth) & ~1)
        let h = max(16, Int(pixelHeight) & ~1)
        return (w, h)
    }

    /// Display o Trackpad (dal Mac o dal menu dell'iPad).
    /// Il cambio avviene al giro successivo del ciclo principale: i selettori segmentati di SwiftUI
    /// possono chiamare il setter mentre la vista si sta aggiornando, e pubblicare lì è vietato.
    func setMode(_ mode: TabletMode) {
        guard TabletMode.available.contains(mode) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, mode != self.activeProfile.mode else { return }
            self.updateActiveProfile { $0.mode = mode }
        }
    }

    /// Zoom/spostamento a due dita sull'iPad: il motore ha già la nuova area; qui si aggiornano
    /// profilo (anteprima e salvataggio) e cattura, SENZA rimandare il profilo al motore.
    private func displayRegionChangedOnIPad(_ id: UUID, _ region: NormRect) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].displayRegion != region else { return }
        profiles[index].displayRegion = region
        scheduleSave()
        if id == activeProfileID { updateMirror() }
    }

    /// Selezione dell'area trascinando sul monitor.
    func selectDisplayRegion() {
        guard let display = DisplayManager.resolve(uuid: activeProfile.displayUUID, in: displays) else { return }
        let surface = connection.surfaceSize
        let aspect: Double? = surface.height > 0 ? Double(surface.width / surface.height) : nil
        RegionSelector.select(on: display, aspectHint: aspect) { [weak self] region in
            guard let self, let region else { return }
            self.updateActiveProfile { $0.displayRegion = region }
        }
    }

    func useFullDisplay() {
        updateActiveProfile { $0.displayRegion = .full }
    }

    /// Allarga l'area alle proporzioni dell'iPad: l'immagine occupa tutto il tablet.
    func fitRegionToIPad() {
        let surface = connection.surfaceSize
        guard surface.height > 0,
              let display = DisplayManager.resolve(uuid: activeProfile.displayUUID, in: displays) else { return }
        let aspect: Double = Double(surface.width / surface.height)
        let size = display.bounds.size
        updateActiveProfile { p in
            p.displayRegion = DisplayRegion.fitted(p.displayRegion, toAspect: aspect, displaySize: size)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = profiles
        let work = DispatchWorkItem { [store] in store.save(snapshot) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Comandi rapidi

    func toggleCursorLock() {
        engine.setCursorLocked(!stats.cursorLocked)
        connections.sendConfig()
    }

    func togglePrecision() {
        engine.setPrecisionMode(!stats.precisionMode)
        connections.sendConfig()
    }

    func toggleEraser() {
        engine.toggleEraser()
        connections.sendConfig()
    }

    private func handleControl(_ c: ControlMessage) {
        switch c.command {
        case .setMode:
            if let m = TabletMode(rawValue: UInt8(clamping: c.value)) { setMode(m) }
        case .nextProfile: break   // un solo insieme di impostazioni: niente profili da scorrere
        case .toggleCursorLock: toggleCursorLock()
        case .togglePrecision: togglePrecision()
        case .setToolbarVisible: updateActiveProfile { $0.toolbarVisible = c.value != 0 }
        case .toggleEraser: toggleEraser()
        }
    }

    private func handle(_ request: EngineRequest) {
        switch request {
        case .nextProfile: break
        case .stateChanged: connections.sendConfig()
        case .needsPermission:
            // Richiesta di sistema una sola volta per avvio; poi solo il banner nella dashboard.
            if !permissionRequested {
                permissionRequested = true
                PermissionManager.requestPostEvents()
            }
        }
    }

    // MARK: - Associazione Wi-Fi

    func beginPairing() {
        pairingPIN = connections.beginPairing()
        pairingDeadline = Date().addingTimeInterval(120)
    }

    func cancelPairing() {
        connections.cancelPairing()
        pairingPIN = nil
        pairingDeadline = nil
    }

    func revokePairings() {
        connections.revokeAllPairings()
    }

    // MARK: - Safari (senza app)

    /// Indirizzi da digitare in Safari sull'iPad.
    var webURLs: [String] {
        NetworkInfo.ipv4Addresses().map { "http://\($0.ip):\(WebClientServer.pagePort)" }
    }

    /// Nuovo codice: le sessioni già aperte restano attive, le nuove useranno il nuovo codice.
    func regenerateWebCode() {
        let code = WebClientServer.newCode()
        KeychainStore.save(Data(code.utf8), account: "web-access-code")
        webCode = code
        connections.setWebCode(code)
        tlog.info("Web: nuovo codice di accesso generato")
    }

    func requestPermission() {
        permissionRequested = true
        if !PermissionManager.requestPostEvents() {
            PermissionManager.openAccessibilitySettings()
        }
        engine.refreshPermission()
    }
}
