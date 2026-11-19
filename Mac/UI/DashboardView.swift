//
//  DashboardView.swift
//  iPad Graphic Tablet — Mac
//
//  Finestra principale: barra laterale + sezioni.
//

import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, pen, mapping, trackpad, buttons, connection, test, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Panoramica"
        case .pen: return "Penna e pressione"
        case .mapping: return "Area e monitor"
        case .trackpad: return "Trackpad"
        case .buttons: return "Pencil e gesti"
        case .connection: return "Connessione"
        case .test: return "Test e diagnostica"
        case .advanced: return "Avanzate"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .pen: return "pencil.tip"
        case .mapping: return "rectangle.dashed"
        case .trackpad: return "hand.point.up.left"
        case .buttons: return "keyboard"
        case .connection: return "cable.connector"
        case .test: return "waveform.path.ecg"
        case .advanced: return "gearshape.2"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var section: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, id: \.self, selection: $section) { s in
                Label(s.title, systemImage: s.symbol)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !state.stats.canPostEvents && state.connection.phase == .connected {
                        PermissionBanner()
                    }
                    detail
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
            }
            .background(Theme.background)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text((section ?? .overview).title)
                .font(.system(size: 26, weight: .semibold))
            Spacer()
        }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .overview {
        case .overview: OverviewView()
        case .pen: PenSettingsView()
        case .mapping: MappingSettingsView()
        case .trackpad: TrackpadSettingsView()
        case .buttons: ButtonsSettingsView()
        case .connection: ConnectionSettingsView()
        case .test: TestDiagnosticsView()
        case .advanced: AdvancedSettingsView()
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            StatusDot(color: phaseColor, pulsing: state.connection.phase == .waiting)
            VStack(alignment: .leading, spacing: 1) {
                Text(phaseText).font(.caption).foregroundStyle(Theme.text)
                if let link = state.connection.link {
                    Text("\(link.rawValue) · \(String(format: "%.1f", state.connection.latency.avgMs)) ms")
                        .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private var phaseColor: Color {
        switch state.connection.phase {
        case .connected: return state.connection.link?.color ?? Theme.ok
        case .waiting: return Theme.warn
        case .idle: return Theme.tertiary
        }
    }

    private var phaseText: String {
        switch state.connection.phase {
        case .connected: return state.connection.deviceName.isEmpty ? "iPad collegato" : state.connection.deviceName
        case .waiting: return "In attesa dell'iPad"
        case .idle: return "Non attivo"
        }
    }
}

/// Avviso permesso Accessibilità.
struct PermissionBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Il cursore non può muoversi: manca il permesso Accessibilità").font(.headline)
                Text("Senza questo permesso macOS scarta in silenzio gli eventi di penna, mouse e tastiera dell'app. Attivalo in Impostazioni di Sistema → Privacy e sicurezza → Accessibilità (nelle versioni recenti di macOS si chiama «Controllo del dispositivo e accesso ai dati»).")
                    .font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Se l'interruttore risulta già acceso: selezionalo, rimuovilo con «−», poi trascina di nuovo l'app nell'elenco (pulsante «Mostra app nel Finder»). Succede dopo ogni nuova compilazione se in Xcode non è impostato un Team. Poi chiudi e riapri l'app.")
                    .font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button("Concedi…") { state.requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Mostra app nel Finder") { PermissionManager.revealAppInFinder() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.5)))
    }
}
