//
//  SessionView.swift
//  iPad Graphic Tablet — iPad
//
//  Modalità tavoletta: superficie nera a tutto schermo, indicatore discreto
//  di connessione, uscita con pressione prolungata, barra strumenti opzionale,
//  indicatore di calibrazione e area attiva (modalità Schermo).
//

import SwiftUI
import UIKit

struct SessionView: View {
    @EnvironmentObject var connection: PadConnectionManager
    @EnvironmentObject var input: TabletInputController
    @AppStorage("dimDuringSession") private var dim = true
    @AppStorage("sessionBrightness") private var sessionBrightness = 0.15
    @State private var exitHint = false

    private var config: SessionConfigMessage? { connection.config }
    private var leftHanded: Bool { config?.leftHanded ?? false }

    var body: some View {
        ZStack {
            if let cfg = config, cfg.mirrorActive {
                MirrorLayer(feed: connection.mirrorFeed, rect: cfg.inputRect, region: cfg.mirrorRegion,
                            status: cfg.mirrorStatus)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if config?.mode == .touchpad {
                // Modalità Trackpad: superficie per le dita.
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .overlay(Text("TRACKPAD").font(.system(size: 12, design: .monospaced)).tracking(2.4)
                        .foregroundStyle(Color.white.opacity(0.18)))
                    .padding(18)
                    .allowsHitTesting(false)
            }

            SurfaceRepresentable(controller: input,
                                 fingerPointer: true,
                                 displayFingers: config?.mode != .touchpad,
                                 palmRejection: config?.palmRejection ?? true)
                .ignoresSafeArea()

            if let cfg = config, cfg.showInputRect, !cfg.mirrorActive {
                InputRectOverlay(rect: cfg.inputRect)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if input.showPenDot, let p = input.penPoint {
                PenDot(point: p)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            overlays
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            ScreenControl.enterSession(dim: dim, level: sessionBrightness)
            ScreenControl.lockCurrentOrientation()
        }
        .onDisappear {
            ScreenControl.exitSession()
            ScreenControl.unlockOrientation()
        }
        .onChange(of: config?.mirrorActive ?? false) { _, mirror in
            if mirror {
                ScreenControl.restoreBrightness()
            } else {
                ScreenControl.enterSession(dim: dim, level: sessionBrightness)
            }
        }
    }

    // MARK: - Overlay

    private var overlays: some View {
        // Stato in alto a destra (a sinistra per i mancini).
        HStack(alignment: .top, spacing: 0) {
            if leftHanded {
                statusColumn
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                statusColumn
            }
        }
    }

    private var statusColumn: some View {
        VStack(alignment: leftHanded ? .leading : .trailing, spacing: 10) {
            statusPill
            if let cfg = config, !cfg.macCanPostEvents {
                Text("Sul Mac concedi il permesso Accessibilità")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(PadTheme.accent.opacity(0.85)))
            }
            if exitHint {
                Text("Tieni premuto ✕ per uscire")
                    .font(.caption)
                    .foregroundStyle(PadTheme.secondary)
            }
        }
        .padding(14)
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            if case .connected(let link, let name) = connection.state {
                Dot(color: link.padColor, size: 7)
                Text("\(link.rawValue) · \(connection.rttMs > 0 ? String(format: "%.0f ms", connection.rttMs) : "—")")
                    .font(PadTheme.mono(11))
                Text(name).font(.caption2).foregroundStyle(PadTheme.tertiary).lineLimit(1)
            }
            if let cfg = config {
                Text("\(cfg.mode == .touchpad ? "TRACKPAD" : "DISPLAY") · \(cfg.displayName)")
                    .font(PadTheme.mono(10))
                    .foregroundStyle(PadTheme.tertiary)
                    .lineLimit(1)
                if cfg.cursorLocked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(PadTheme.warn) }
                if cfg.precisionMode { Image(systemName: "scope").font(.caption2).foregroundStyle(PadTheme.accent) }
                if cfg.eraserActive { Image(systemName: "eraser").font(.caption2).foregroundStyle(PadTheme.warn) }
            }
            // Indicatore di calibrazione
            Image(systemName: input.calibration.isIdentity ? "scope" : "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(input.calibration.isIdentity ? PadTheme.tertiary : PadTheme.ok)
            modeMenu
            exitButton
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .opacity(0.75)
    }

    private var modeMenu: some View {
        Menu {
            Section("Modalità") {
                ForEach(TabletMode.available) { m in
                    Button { input.control(.setMode, value: Int32(m.rawValue)) } label: {
                        if config?.mode == m { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
            }
            Button { input.control(.toggleCursorLock) } label: {
                Label(config?.cursorLocked == true ? "Sblocca cursore" : "Blocca cursore", systemImage: "lock")
            }
            Button { input.control(.togglePrecision) } label: { Label("Modalità precisione", systemImage: "scope") }
            Button { input.control(.toggleEraser) } label: { Label("Penna ↔ gomma", systemImage: "eraser") }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
    }

    private var exitButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.white.opacity(0.1)))
            .onTapGesture {
                exitHint = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exitHint = false }
            }
            .onLongPressGesture(minimumDuration: 0.6) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                connection.pause()
            }
    }
}


/// Schermo del Mac (modalità Display) dentro l'area di input.
struct MirrorLayer: View {
    @ObservedObject var feed: MirrorFeed
    let rect: NormRect
    /// Area del monitor mostrata ora (cambia con zoom e spostamento a due dita).
    let region: NormRect
    let status: String

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = CGFloat(rect.width) * geo.size.width
            let h: CGFloat = CGFloat(rect.height) * geo.size.height
            let x: CGFloat = CGFloat(rect.x) * geo.size.width + w / 2
            let y: CGFloat = CGFloat(rect.y) * geo.size.height + h / 2
            if let frame = feed.frame {
                // Il fotogramma riporta la propria area: dopo uno zoom si adatta subito alla nuova vista.
                let p: NormRect = DisplayViewport.placement(frame: frame.region, view: region)
                let fw: CGFloat = CGFloat(p.width) * w
                let fh: CGFloat = CGFloat(p.height) * h
                let fx: CGFloat = CGFloat(p.x) * w + fw / 2
                let fy: CGFloat = CGFloat(p.y) * h + fh / 2
                ZStack {
                    Color.black
                    Image(uiImage: frame.image)
                        .resizable()
                        .frame(width: fw, height: fh)
                        .position(x: fx, y: fy)
                }
                .frame(width: w, height: h)
                .clipped()
                .position(x: x, y: y)
            } else {
                Text(status.isEmpty ? "In attesa dello schermo del Mac…" : status)
                    .foregroundStyle(PadTheme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: geo.size.width * 0.7)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}

/// Rettangolo dell'area attiva (modalità Schermo).
struct InputRectOverlay: View {
    let rect: NormRect

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(x: CGFloat(rect.x) * geo.size.width, y: CGFloat(rect.y) * geo.size.height,
                           width: CGFloat(rect.width) * geo.size.width, height: CGFloat(rect.height) * geo.size.height)
            Path(r).stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }
}

/// Punto di riferimento opzionale della penna (spento di default per lo schermo nero).
struct PenDot: View {
    let point: CGPoint
    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
                .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
        }
    }
}

/// Ponte SwiftUI ↔ UIKit per la superficie di cattura.
struct SurfaceRepresentable: UIViewRepresentable {
    let controller: TabletInputController
    var fingerPointer: Bool
    var displayFingers: Bool
    var palmRejection: Bool

    func makeUIView(context: Context) -> PencilSurfaceView {
        let v = PencilSurfaceView(frame: .zero)
        v.delegate = controller
        controller.surface = v
        v.fingerPointerEnabled = fingerPointer
        v.displayFingers = displayFingers
        v.palmRejection = palmRejection
        return v
    }

    func updateUIView(_ v: PencilSurfaceView, context: Context) {
        if v.fingerPointerEnabled != fingerPointer { v.fingerPointerEnabled = fingerPointer }
        v.displayFingers = displayFingers
        v.palmRejection = palmRejection
    }
}
