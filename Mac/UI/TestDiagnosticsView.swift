//
//  TestDiagnosticsView.swift
//  iPad Graphic Tablet — Mac
//
//  Banco di prova: una tela Cocoa che legge gli NSEvent ESATTAMENTE come
//  un'app di grafica. Se qui la pressione varia, il percorso iPad → rete →
//  CGEvent → WindowServer → AppKit funziona; ciò che resta da verificare è
//  solo il comportamento della singola app (vedi docs/TEST.md).
//

import SwiftUI
import AppKit

struct PressureReading: Equatable {
    var eventType = "—"
    var isTabletEvent = false
    var pressure: Double = 0
    var tiltX: Double = 0
    var tiltY: Double = 0
    var rotation: Double = 0
    var pointer = "—"
    var inProximity = false
    var capabilityMask = 0
    var vendorID = 0
    var tabletEvents = 0
    var otherEvents = 0
}

struct TestDiagnosticsView: View {
    @EnvironmentObject var state: AppState
    @State private var reading = PressureReading()
    @State private var clearToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card("Test pressione (eventi Cocoa reali)", trailing: AnyView(
                Button("Pulisci") { clearToken += 1 }.buttonStyle(.bordered).controlSize(.small))) {
                Text("Disegna qui con la Apple Pencil (modalità Schermo o Photoshop, area su questo monitor). Lo spessore del tratto segue NSEvent.pressure.")
                    .font(.callout).foregroundStyle(Theme.secondary)
                PressureCanvas(reading: $reading, clearToken: clearToken)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                HStack {
                    Metric(label: "Evento", value: reading.eventType)
                    Metric(label: "Pressione", value: String(format: "%.3f", reading.pressure))
                    Metric(label: "Tilt", value: String(format: "%.2f / %.2f", reading.tiltX, reading.tiltY))
                    Metric(label: "Puntatore", value: reading.pointer)
                }
                HStack(spacing: 16) {
                    verdict
                    Spacer()
                    Text("tablet: \(reading.tabletEvents) · altri: \(reading.otherEvents) · mask: 0x\(String(reading.capabilityMask, radix: 16))")
                        .font(Theme.mono(10)).foregroundStyle(Theme.tertiary)
                }
            }

            Card("Latenza") {
                let l = state.connection.latency
                HStack {
                    Metric(label: "Ultimo", value: f(l.lastMs), unit: "ms")
                    Metric(label: "Min", value: f(l.minMs), unit: "ms")
                    Metric(label: "Media", value: f(l.avgMs), unit: "ms")
                    Metric(label: "p95", value: f(l.p95Ms), unit: "ms")
                    Metric(label: "Jitter", value: f(l.jitterMs), unit: "ms")
                }
                HStack {
                    Metric(label: "Penna → Mac", value: state.stats.penLatencyMs.map(f) ?? "—", unit: "ms")
                    Metric(label: "Frequenza", value: "\(Int(state.stats.sampleRate))", unit: "Hz")
                    Metric(label: "Eventi", value: "\(state.stats.eventsPosted)")
                    Metric(label: "Campioni persi", value: "\(state.stats.sequenceGaps)")
                    Metric(label: "Gesti dita", value: "\(state.stats.fingerGestures)")
                }
                Text("RTT misurato con ping ogni secondo su \(l.count) campioni. \"Penna → Mac\" è stimata sincronizzando gli orologi dei due dispositivi (stile NTP) e non include il tempo di disegno dell'app.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card("Registro") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(state.logLines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                    }
                    .frame(height: 220)
                    .onChange(of: state.logLines.count) { _, n in
                        proxy.scrollTo(n - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder private var verdict: some View {
        if reading.tabletEvents == 0 {
            Label("Nessun evento tablet ancora ricevuto", systemImage: "circle.dashed")
                .foregroundStyle(Theme.secondary)
        } else if reading.pressure > 0 && reading.isTabletEvent {
            Label("Pressione ricevuta dalle app Cocoa", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.ok)
        } else {
            Label("Eventi tablet ricevuti — premi la punta per vedere la pressione", systemImage: "info.circle")
                .foregroundStyle(Theme.warn)
        }
    }

    private func f(_ v: Double) -> String { v == 0 ? "—" : String(format: "%.1f", v) }
}

/// Tela AppKit che riceve gli eventi del mouse/tavoletta.
struct PressureCanvas: NSViewRepresentable {
    @Binding var reading: PressureReading
    var clearToken: Int

    func makeNSView(context: Context) -> PressureCanvasView {
        let v = PressureCanvasView()
        v.onReading = { r in DispatchQueue.main.async { reading = r } }
        return v
    }

    func updateNSView(_ v: PressureCanvasView, context: Context) {
        v.onReading = { r in DispatchQueue.main.async { reading = r } }
        if v.clearToken != clearToken {
            v.clearToken = clearToken
            v.clear()
        }
    }
}

final class PressureCanvasView: NSView {
    private struct StrokePoint { var p: NSPoint; var pressure: CGFloat }
    private var strokes: [[StrokePoint]] = []
    private var current: [StrokePoint] = []
    private var reading = PressureReading()
    var clearToken = 0
    var onReading: ((PressureReading) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func clear() {
        strokes.removeAll()
        current.removeAll()
        reading = PressureReading()
        onReading?(reading)
        needsDisplay = true
    }

    private func record(_ event: NSEvent, name: String) {
        let isTablet = event.subtype == .tabletPoint
        reading.eventType = name
        reading.isTabletEvent = isTablet
        if isTablet {
            reading.tabletEvents += 1
            reading.pressure = Double(event.pressure)
            reading.tiltX = Double(event.tilt.x)
            reading.tiltY = Double(event.tilt.y)
            reading.rotation = Double(event.rotation)
        } else {
            reading.otherEvents += 1
            reading.pressure = Double(event.pressure)
        }
        onReading?(reading)
    }

    private func point(_ event: NSEvent) -> StrokePoint {
        let isTablet = event.subtype == .tabletPoint
        return StrokePoint(p: convert(event.locationInWindow, from: nil),
                           pressure: isTablet ? CGFloat(event.pressure) : 0.5)
    }

    override func mouseDown(with event: NSEvent) {
        current = [point(event)]
        record(event, name: "down")
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current.append(point(event))
        record(event, name: "drag")
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if current.count > 1 { strokes.append(current) }
        current = []
        record(event, name: "up")
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if event.subtype == .tabletPoint { record(event, name: "hover") }
    }

    override func tabletProximity(with event: NSEvent) {
        reading.inProximity = event.isEnteringProximity
        reading.capabilityMask = Int(event.capabilityMask)
        reading.vendorID = event.vendorID
        switch event.pointingDeviceType {
        case .pen: reading.pointer = "penna"
        case .eraser: reading.pointer = "gomma"
        case .cursor: reading.pointer = "cursore"
        default: reading.pointer = "?"
        }
        if !event.isEnteringProximity { reading.pointer += " (fuori)" }
        onReading?(reading)
    }

    override func tabletPoint(with event: NSEvent) {
        record(event, name: "tablet")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        // griglia a punti
        NSColor.white.withAlphaComponent(0.08).setFill()
        stride(from: CGFloat(10), to: bounds.width, by: 20).forEach { x in
            stride(from: CGFloat(10), to: bounds.height, by: 20).forEach { y in
                NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
            }
        }
        for stroke in strokes + [current] where stroke.count > 1 {
            for i in 1..<stroke.count {
                let a = stroke[i - 1], b = stroke[i]
                let path = NSBezierPath()
                path.move(to: a.p)
                path.line(to: b.p)
                path.lineCapStyle = .round
                let average: CGFloat = (a.pressure + b.pressure) / 2
                let alpha: CGFloat = 0.25 + 0.75 * b.pressure
                path.lineWidth = 1 + average * 22
                NSColor.white.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
        }
    }
}
