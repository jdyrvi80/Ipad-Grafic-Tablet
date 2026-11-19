//
//  PenSettingsView.swift
//  iPad Graphic Tablet — Mac
//
//  Curva di pressione, sensibilità minima/massima, soglia di click,
//  stabilizzazione, inclinazione, hover e palm rejection.
//

import SwiftUI

struct PenSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card("Curva di pressione", trailing: AnyView(presetButtons)) {
                HStack(alignment: .top, spacing: 24) {
                    PressureCurveEditor(curve: state.binding(\.pressureCurve),
                                        liveInput: Double(state.stats.rawPressure),
                                        liveOutput: state.stats.outputPressure,
                                        live: state.stats.tipDown)
                        .frame(width: 300, height: 300)
                    VStack(alignment: .leading, spacing: 10) {
                        sensitivitySliders
                        if !state.connection.capabilities.contains(.pressure) && state.connection.phase == .connected {
                            Label("Questo iPad/Pencil non riporta variazioni di pressione (es. Apple Pencil USB-C): la punta invia sempre pressione piena, senza simulazioni.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Theme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Card("Stabilizzazione e precisione") {
                SettingRow(title: "Riduzione del tremolio",
                           help: "Filtro adattivo: agisce sui movimenti lenti e quasi non tocca quelli veloci.") {
                    ValueSlider(value: state.binding(\.stabilization), range: 0...1,
                                format: { "\(Int($0 * 100))%" })
                }
                SettingRow(title: "Fattore modalità precisione",
                           help: "Frazione del movimento reale applicata quando la precisione è attiva.") {
                    ValueSlider(value: state.binding(\.precisionFactor), range: 0.1...1,
                                format: { "×\(String(format: "%.2f", $0))" })
                }
            }

            Card("Comportamento") {
                SettingRow(title: "Inclinazione", help: "Invia inclinazione (tilt) alle app compatibili.") {
                    Toggle("", isOn: state.binding(\.sendTilt)).labelsHidden()
                }
                SettingRow(title: "Hover muove il cursore",
                           help: "Sugli iPad con hover della Pencil il cursore segue la penna sollevata, come una Wacom.") {
                    Toggle("", isOn: state.binding(\.hoverMovesCursor)).labelsHidden()
                }
                SettingRow(title: "Palm rejection",
                           help: "Ignora il palmo e le dita mentre la Pencil è vicina o a contatto.") {
                    Toggle("", isOn: state.binding(\.palmRejection)).labelsHidden()
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    private var presetButtons: some View {
        HStack(spacing: 6) {
            curvePreset("Morbida", .soft)
            curvePreset("Lineare", .linear)
            curvePreset("Rigida", .firm)
        }
    }

    private func curvePreset(_ title: String, _ preset: PressureCurve) -> some View {
        Button(title) {
            state.updateActiveProfile { p in
                p.pressureCurve.control1 = preset.control1
                p.pressureCurve.control2 = preset.control2
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private var sensitivitySliders: some View {
        let curve = state.binding(\.pressureCurve)
        VStack(alignment: .leading, spacing: 4) {
            Text("Sensibilità minima").font(.callout)
            Text("Pressione sotto la quale il tratto resta al minimo.").font(.caption).foregroundStyle(Theme.secondary)
            ValueSlider(value: floatBinding(curve, \.minimumInput), range: 0...0.6,
                        format: { "\(Int($0 * 100))%" })
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Sensibilità massima").font(.callout)
            Text("Pressione oltre la quale si raggiunge il 100%.").font(.caption).foregroundStyle(Theme.secondary)
            ValueSlider(value: floatBinding(curve, \.maximumInput), range: 0.3...1,
                        format: { "\(Int($0 * 100))%" })
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Soglia di click").font(.callout)
            Text("Sotto questa pressione la punta muove soltanto il cursore (utile sugli iPad senza hover).")
                .font(.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ValueSlider(value: floatBinding(curve, \.tipThreshold), range: 0...0.4,
                        format: { "\(Int($0 * 100))%" })
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Pressione minima in uscita").font(.callout)
            ValueSlider(value: floatBinding(curve, \.outputFloor), range: 0...0.3,
                        format: { "\(Int($0 * 100))%" })
        }
    }

    private func floatBinding(_ curve: Binding<PressureCurve>, _ kp: WritableKeyPath<PressureCurve, Float>) -> Binding<Double> {
        Binding(get: { Double(curve.wrappedValue[keyPath: kp]) },
                set: { curve.wrappedValue[keyPath: kp] = Float($0) })
    }
}

/// Editor grafico della Bézier con due maniglie trascinabili e il punto live.
struct PressureCurveEditor: View {
    @Binding var curve: PressureCurve
    var liveInput: Double
    var liveOutput: Double
    var live: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, sz in
                    // Griglia a punti (stile Nothing)
                    let step: CGFloat = sz.width / 10
                    for i in 0...10 {
                        for j in 0...10 {
                            let px: CGFloat = CGFloat(i) * step - 1
                            let py: CGFloat = CGFloat(j) * step - 1
                            ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 2, height: 2)),
                                     with: .color(.white.opacity(0.12)))
                        }
                    }
                    // Diagonale di riferimento
                    var diag = Path()
                    diag.move(to: CGPoint(x: 0, y: sz.height))
                    diag.addLine(to: CGPoint(x: sz.width, y: 0))
                    ctx.stroke(diag, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    // Linee verso le maniglie
                    var guides = Path()
                    guides.move(to: CGPoint(x: 0, y: sz.height))
                    guides.addLine(to: point(curve.control1, sz))
                    guides.move(to: CGPoint(x: sz.width, y: 0))
                    guides.addLine(to: point(curve.control2, sz))
                    ctx.stroke(guides, with: .color(.white.opacity(0.25)), lineWidth: 1)
                    // Curva effettiva (incluse sensibilità min/max)
                    var path = Path()
                    for (i, p) in curve.sampled(count: 96).enumerated() {
                        let pt = point(p, sz)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(.white), lineWidth: 2)
                    // Punto live
                    if live {
                        let lx: CGFloat = CGFloat(liveInput) * sz.width
                        let ly: CGFloat = sz.height - CGFloat(liveOutput) * sz.height
                        ctx.fill(Path(ellipseIn: CGRect(x: lx - 5, y: ly - 5, width: 10, height: 10)),
                                 with: .color(Theme.accent))
                    }
                }
                handle(\.control1, size: size)
                handle(\.control2, size: size)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(alignment: .bottomLeading) {
            Text("PRESSIONE PENNA →").font(Theme.mono(9)).foregroundStyle(Theme.tertiary).padding(6)
        }
    }

    private func point(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        let x: CGFloat = CGFloat(p.x) * size.width
        let y: CGFloat = size.height - CGFloat(p.y) * size.height
        return CGPoint(x: x, y: y)
    }

    private func handle(_ kp: WritableKeyPath<PressureCurve, CurvePoint>, size: CGSize) -> some View {
        let p = point(curve[keyPath: kp], size)
        return Circle()
            .fill(Theme.accent)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .position(p)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let nx: CGFloat = g.location.x / size.width
                let ny: CGFloat = 1 - g.location.y / size.height
                let x = Float(min(max(nx, 0), 1))
                let y = Float(min(max(ny, 0), 1))
                curve[keyPath: kp] = CurvePoint(x: x, y: y)
            })
    }
}
