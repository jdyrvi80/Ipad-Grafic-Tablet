//
//  MenuBarContent.swift
//  iPad Graphic Tablet — Mac
//
//  Pannello della barra dei menu: stato, profilo, modalità e comandi rapidi.
//

import SwiftUI
import AppKit

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var c: ConnectionSnapshot { state.connection }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(color: statusColor, pulsing: c.phase != .connected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.phase == .connected ? c.deviceName : "In attesa dell'iPad")
                        .font(.headline)
                    if let link = c.link {
                        Text("\(link.rawValue) · \(String(format: "%.1f", c.latency.avgMs)) ms · \(Int(state.stats.sampleRate)) Hz")
                            .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
            }

            if !state.stats.canPostEvents && c.phase == .connected {
                Button { state.requestPermission() } label: {
                    Label("Concedi permesso Accessibilità", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }

            Picker("Modalità", selection: Binding(get: { state.activeProfile.mode }, set: { state.setMode($0) })) {
                ForEach(TabletMode.available) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)

            SegmentBar(value: state.stats.outputPressure, segments: 30, color: Theme.accent)

            HStack {
                toggleButton("Blocca", "lock", state.stats.cursorLocked) { state.toggleCursorLock() }
                toggleButton("Precisione", "scope", state.stats.precisionMode) { state.togglePrecision() }
                toggleButton("Gomma", "eraser", state.stats.eraserActive) { state.toggleEraser() }
            }

            Divider()

            HStack {
                Button("Apri dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var statusColor: Color {
        guard c.phase == .connected else { return Theme.warn }
        return c.link?.color ?? Theme.ok
    }

    private func toggleButton(_ title: String, _ symbol: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Self.toggleFill(on)))
        }
        .buttonStyle(.plain)
    }

    private static func toggleFill(_ on: Bool) -> Color {
        on ? Theme.accent.opacity(0.3) : Color.white.opacity(0.06)
    }
}
