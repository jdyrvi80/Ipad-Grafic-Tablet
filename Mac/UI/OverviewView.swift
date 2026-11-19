//
//  OverviewView.swift
//  iPad Graphic Tablet — Mac
//
//  Dashboard: stato connessione, iPad, collegamento, latenza, penna in tempo
//  reale, modalità, monitor e profili.
//

import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var state: AppState

    private var c: ConnectionSnapshot { state.connection }
    private var s: EngineStats { state.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                connectionCard
                penCard
            }
            HStack(alignment: .top, spacing: 16) {
                sessionCard
                quickCard
            }
        }
    }

    // MARK: Connessione

    private var connectionCard: some View {
        Card("Connessione") {
            HStack(spacing: 10) {
                StatusDot(color: connectionColor, pulsing: c.phase != .connected)
                Text(connectionTitle)
                    .font(.title3.weight(.semibold))
                Spacer()
                if let link = c.link {
                    Label(link.rawValue, systemImage: link.symbol)
                        .font(Theme.mono(12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(link.color.opacity(0.18)))
                        .foregroundStyle(link.color)
                }
            }
            if c.phase == .connected {
                Text(deviceLine)
                    .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
            } else {
                Text("Senza app: apri in Safari sull'iPad l'indirizzo mostrato in Connessione. Con l'app: collega il cavo o scegli questo Mac dall'elenco Wi-Fi.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
            Divider().overlay(Theme.stroke)
            HStack {
                Metric(label: "Latenza", value: fmt(c.latency.avgMs), unit: "ms")
                Metric(label: "p95", value: fmt(c.latency.p95Ms), unit: "ms")
                Metric(label: "Campioni", value: "\(Int(s.sampleRate))", unit: "Hz")
                Metric(label: "Penna→Mac", value: penLatencyText, unit: "ms")
            }
        }
    }

    // MARK: Penna

    private var penCard: some View {
        Card("Penna") {
            HStack(spacing: 8) {
                StatusDot(color: penColor)
                Text(penStateText)
                    .font(.callout)
                Spacer()
                if s.eraserActive {
                    Label("Gomma", systemImage: "eraser").font(.caption).foregroundStyle(Theme.warn)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PRESSIONE").font(Theme.mono(10)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text(pressureText)
                        .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                }
                SegmentBar(value: s.outputPressure, color: Theme.accent)
            }
            HStack {
                Metric(label: "Incl. X", value: fmt2(s.tiltX))
                Metric(label: "Incl. Y", value: fmt2(s.tiltY))
                Metric(label: "Rotazione", value: rollText)
            }
            capabilitiesRow
        }
    }

    private var capabilitiesRow: some View {
        let all: [(DeviceCapabilities, String)] = [
            (.pressure, "Pressione"), (.tilt, "Inclinazione"), (.hover, "Hover"),
            (.doubleTap, "Doppio tocco"), (.squeeze, "Squeeze"), (.roll, "Rotazione"),
        ]
        return HStack(spacing: 6) {
            ForEach(0..<all.count, id: \.self) { i in
                CapabilityChip(title: all[i].1, isOn: c.capabilities.contains(all[i].0))
            }
        }
        .help("Le funzioni si attivano solo quando l'iPad le rileva davvero (es. hover e squeeze dopo il primo utilizzo).")
    }

    // MARK: Sessione

    private var sessionCard: some View {
        Card("Sessione") {
            SettingRow(title: "Modalità", help: state.activeProfile.mode.summary) {
                Picker("", selection: Binding(get: { state.activeProfile.mode }, set: { state.setMode($0) })) {
                    ForEach(TabletMode.available) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            SettingRow(title: "Monitor") {
                Picker("", selection: state.binding(\.displayUUID)) {
                    Text("Monitor principale").tag(String?.none)
                    ForEach(state.displays) { d in Text(d.name).tag(Optional(d.uuid)) }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            SettingRow(title: "Sensibilità", help: curveDescription) {
                CurveThumbnail(curve: state.activeProfile.pressureCurve)
                    .frame(width: 64, height: 40)
            }
        }
    }

    private var curveDescription: String {
        let c = state.activeProfile.pressureCurve
        let mid = c.apply(0.5)
        var kind = "lineare"
        if mid > 0.58 { kind = "morbida" } else if mid < 0.42 { kind = "rigida" }
        return "Curva \(kind) · ingresso \(Int(c.minimumInput * 100))–\(Int(c.maximumInput * 100))% · stabilizzazione \(Int(state.activeProfile.stabilization * 100))%"
    }

    // MARK: Comandi rapidi

    private var quickCard: some View {
        Card("Comandi rapidi") {
            Toggle(isOn: Binding(get: { s.cursorLocked }, set: { _ in state.toggleCursorLock() })) {
                Label("Blocca cursore", systemImage: "lock")
            }
            Toggle(isOn: Binding(get: { s.precisionMode }, set: { _ in state.togglePrecision() })) {
                Label("Modalità precisione", systemImage: "scope")
            }
            Toggle(isOn: Binding(get: { s.eraserActive }, set: { _ in state.toggleEraser() })) {
                Label("Puntatore gomma", systemImage: "eraser")
            }
            Toggle(isOn: state.binding(\.toolbarVisible)) {
                Label("Barra strumenti sull'iPad", systemImage: "sidebar.left")
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .frame(width: 300)
    }

    // Valori calcolati fuori dalle viste: le condizioni dentro i modificatori rallentano il compilatore.

    private var deviceLine: String {
        let size = "\(Int(c.surfaceSize.width))×\(Int(c.surfaceSize.height)) pt"
        var parts: [String] = []
        if c.link != .web { parts.append(c.deviceModel) }
        parts.append(c.link == .web ? c.systemVersion : "iPadOS \(c.systemVersion)")
        parts.append(size)
        return parts.joined(separator: " · ")
    }

    private var connectionColor: Color {
        guard c.phase == .connected else { return Theme.warn }
        return c.link?.color ?? Theme.ok
    }

    private var connectionTitle: String {
        c.phase == .connected ? c.deviceName : "In attesa dell'iPad…"
    }

    private var penColor: Color {
        if s.tipDown { return Theme.accent }
        return s.inProximity ? Theme.ok : Theme.tertiary
    }

    private var penStateText: String {
        if s.tipDown { return "Punta a contatto" }
        return s.inProximity ? "In prossimità" : "Fuori portata"
    }

    private var pressureText: String {
        c.capabilities.contains(.pressure) ? fmt2(s.outputPressure) : "non disponibile"
    }

    private var rollText: String {
        guard c.capabilities.contains(.roll) else { return "—" }
        return "\(Int(s.rollDegrees))°"
    }

    private var penLatencyText: String {
        guard let ms = s.penLatencyMs else { return "—" }
        return fmt(ms)
    }

    private func fmt(_ v: Double) -> String { v == 0 ? "—" : String(format: "%.1f", v) }
    private func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
}

/// Anteprima piccola della curva di pressione.
struct CurveThumbnail: View {
    var curve: PressureCurve

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for (i, p) in curve.sampled(count: 32).enumerated() {
                let px: CGFloat = CGFloat(p.x) * size.width
                let py: CGFloat = size.height - CGFloat(p.y) * size.height
                let pt = CGPoint(x: px, y: py)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.12)), lineWidth: 1)
            ctx.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
    }
}

/// Etichetta di una capacità (attiva / non rilevata).
struct CapabilityChip: View {
    let title: String
    let isOn: Bool

    private var fill: Color { isOn ? Color.white.opacity(0.14) : Color.clear }
    private var border: Color { Color.white.opacity(isOn ? 0 : 0.12) }
    private var textColor: Color { isOn ? Theme.text : Theme.tertiary }

    var body: some View {
        Text(title)
            .font(Theme.mono(10))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border))
            .foregroundStyle(textColor)
    }
}
