//
//  DisplayModeCard.swift
//  iPad Graphic Tablet — Mac
//
//  Impostazioni della modalità Display: monitor, area mostrata sull'iPad,
//  qualità e stato della trasmissione.
//

import SwiftUI
import AppKit

struct DisplayModeCard: View {
    @EnvironmentObject var state: AppState

    private var profile: TabletProfile { state.activeProfile }
    private var stats: MirrorStats { state.mirrorStats }

    private var display: DisplayInfo? {
        DisplayManager.resolve(uuid: profile.displayUUID, in: state.displays)
    }

    private var regionText: String {
        let r = profile.displayRegion.clamped()
        if r == .full { return "Tutto lo schermo" }
        guard let d = display else { return "Area personalizzata" }
        let rect = DisplayRegion.localRect(r, displaySize: d.bounds.size)
        return "\(Int(rect.width)) × \(Int(rect.height)) pt, da (\(Int(rect.minX)), \(Int(rect.minY)))"
    }

    private var statusText: String {
        if !stats.message.isEmpty { return stats.message }
        if state.connection.phase != .connected { return "In attesa dell'iPad" }
        if !state.connection.capabilities.contains(.videoDisplay) {
            return "Il client collegato non mostra lo schermo: aggiorna la pagina Safari o l'app iPad"
        }
        if stats.running {
            let fps = Int(stats.fps)
            let kb = Int(stats.averageKB)
            var text = "In trasmissione · \(stats.pixelWidth)×\(stats.pixelHeight) px · \(fps) fps · \(kb) KB/fotogramma"
            if profile.mirrorSharpenWhenIdle && stats.sharpWidth > 0 {
                text += " · da fermo \(stats.sharpWidth)×\(stats.sharpHeight) px"
            }
            return text
        }
        return "Avvio della cattura…"
    }

    private var statusColor: Color {
        if !stats.message.isEmpty { return Theme.warn }
        return stats.running ? Theme.ok : Theme.tertiary
    }

    private var gestureSubtitle: String {
        switch profile.displayGestures {
        case .area: return "Pizzica per ingrandire, trascina per spostare l'area. Allargando al massimo torni a tutto lo schermo."
        case .app: return "Trascinamento = scorrimento, pizzico = scorciatoie di zoom del profilo (es. ⌘+ / ⌘−)."
        }
    }

    private var canFit: Bool {
        state.connection.phase == .connected && state.connection.surfaceSize.height > 0
    }

    var body: some View {
        Card("Display — lo schermo del Mac sull'iPad") {
            Text("L'iPad mostra l'area scelta del monitor e la penna disegna esattamente sotto la punta, come una tavoletta con schermo. Puoi mostrare tutto il monitor o solo una parte, per esempio la tela di Photoshop: più l'area è piccola, più è ingrandita sull'iPad.")
                .font(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Un dito che scorre muove il cursore come un trackpad; tocco e doppio tocco cliccano nel punto toccato. La Apple Pencil clicca, trascina e disegna dove tocca, con la pressione.",
                  systemImage: "hand.point.up.left")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            SettingRow(title: "Due dita", help: gestureSubtitle) {
                Picker("", selection: state.binding(\.displayGestures)) {
                    ForEach(DisplayGestureTarget.allCases) { t in Text(t.title).tag(t) }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            SettingRow(title: "Monitor") {
                Picker("", selection: state.binding(\.displayUUID)) {
                    Text("Monitor principale").tag(String?.none)
                    ForEach(state.displays) { d in Text(d.name).tag(Optional(d.uuid)) }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            HStack(alignment: .top, spacing: 20) {
                RegionPreview(region: profile.displayRegion.clamped(), displayAspect: display?.aspect ?? 16.0 / 9.0)
                    .frame(width: 240, height: 150)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Area mostrata").font(.callout)
                    Text(regionText).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                    Button {
                        state.selectDisplayRegion()
                    } label: {
                        Label("Seleziona area sullo schermo…", systemImage: "rectangle.dashed")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    HStack {
                        Button("Tutto lo schermo") { state.useFullDisplay() }
                        Button("Proporzioni dell'iPad") { state.fitRegionToIPad() }
                            .disabled(!canFit)
                            .help("Allarga l'area alle proporzioni dell'iPad: l'immagine riempie tutto il tablet, senza bande nere.")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider().overlay(Theme.stroke)
            Text("QUALITÀ SULL'IPAD").font(Theme.mono(11, weight: .medium)).tracking(1.4)
                .foregroundStyle(Theme.secondary)

            SettingRow(title: "Impostazione rapida", help: presetHelp) {
                Picker("", selection: presetBinding) {
                    ForEach(MirrorQualityPreset.allCases) { p in Text(p.title).tag(Optional(p)) }
                    if MirrorQualityPreset.matching(profile) == nil {
                        Text("Personalizzata").tag(MirrorQualityPreset?.none)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
            SettingRow(title: "Risoluzione",
                       help: "100% = Retina: un pixel inviato per ogni pixel dello schermo dell'iPad (massima definizione). Mai oltre i pixel reali del monitor.") {
                ValueSlider(value: state.binding(\.mirrorResolution), range: 0.3...1, step: 0.05,
                            format: { "\(Int(($0 * 100).rounded()))%" })
            }
            SettingRow(title: "Qualità JPEG", help: "Più alta = meno artefatti su testi e bordi, ma più dati sulla rete.") {
                ValueSlider(value: state.binding(\.mirrorQuality), range: 0.3...1, step: 0.05,
                            format: { "\(Int(($0 * 100).rounded()))%" })
            }
            SettingRow(title: "Fotogrammi al secondo (massimo)",
                       help: "La frequenza reale si adatta da sola alla velocità della rete.") {
                ValueSlider(value: fpsBinding, range: 10...60, step: 5, format: { "\(Int($0))" })
            }
            SettingRow(title: "Massima nitidezza da fermo",
                       help: "Quando lo schermo smette di cambiare, l'iPad riceve subito una versione a piena risoluzione Retina e qualità 95%: il movimento resta fluido, l'immagine ferma è nitida.") {
                Toggle("", isOn: state.binding(\.mirrorSharpenWhenIdle)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }

            HStack(spacing: 8) {
                StatusDot(color: statusColor, pulsing: !stats.running && stats.message.isEmpty)
                Text(statusText).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                Spacer()
                if !CGPreflightScreenCaptureAccess() {
                    Button("Privacy → Registrazione schermo") { state.openScreenRecordingSettings() }
                        .buttonStyle(.bordered)
                }
            }
            Text("Serve il permesso Registrazione schermo: dopo averlo concesso riapri l'app. macOS lo riconferma periodicamente.")
                .font(.caption).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetBinding: Binding<MirrorQualityPreset?> {
        Binding(get: { MirrorQualityPreset.matching(state.activeProfile) },
                set: { preset in
                    guard let preset else { return }
                    state.updateActiveProfile { preset.apply(to: &$0) }
                })
    }

    private var presetHelp: String {
        switch MirrorQualityPreset.matching(profile) {
        case .smooth?: return "Movimento più scorrevole su reti lente; l'immagine ferma diventa nitida da sola."
        case .balanced?: return "Buon compromesso per il Wi-Fi di casa."
        case .sharp?: return "Risoluzione Retina piena: testi e dettagli definiti. Serve un Wi-Fi veloce (5 GHz)."
        case .maximum?: return "Qualità quasi senza perdita, a 20 fotogrammi al secondo: per ritocco e controllo del dettaglio."
        case nil: return "Valori scelti a mano con i cursori qui sotto."
        }
    }

    private var fpsBinding: Binding<Double> {
        Binding(get: { Double(state.activeProfile.mirrorMaxFPS) },
                set: { v in state.updateActiveProfile { $0.mirrorMaxFPS = Int(v) } })
    }
}

/// Anteprima del monitor con l'area mostrata sull'iPad.
struct RegionPreview: View {
    let region: NormRect
    let displayAspect: Double

    private func frames(in container: CGSize) -> (screen: CGRect, area: CGRect) {
        let aspect = CGFloat(displayAspect)
        var w: CGFloat = container.width
        var h: CGFloat = w / aspect
        if h > container.height {
            h = container.height
            w = h * aspect
        }
        let x0: CGFloat = (container.width - w) / 2
        let y0: CGFloat = (container.height - h) / 2
        let screen = CGRect(x: x0, y: y0, width: w, height: h)
        let ax: CGFloat = x0 + CGFloat(region.x) * w
        let ay: CGFloat = y0 + CGFloat(region.y) * h
        let aw: CGFloat = CGFloat(region.width) * w
        let ah: CGFloat = CGFloat(region.height) * h
        return (screen, CGRect(x: ax, y: ay, width: aw, height: ah))
    }

    var body: some View {
        GeometryReader { geo in
            let f = frames(in: geo.size)
            ZStack(alignment: .topLeading) {
                Path(f.screen).fill(Color.white.opacity(0.06))
                Path(f.screen).stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                Path(f.area).fill(Theme.accent.opacity(0.22))
                Path(f.area).stroke(Theme.accent, lineWidth: 1.5)
            }
        }
    }
}
