//
//  ConnectView.swift
//  iPad Graphic Tablet — iPad
//
//  Schermata iniziale: USB, Mac trovati in Wi-Fi, IP manuale, associazione,
//  capacità rilevate della Pencil, calibrazione e impostazioni.
//

import SwiftUI
import Network
import UIKit

struct PairingRequest: Identifiable {
    let id = UUID()
    var macName: String
    var endpoint: NWEndpoint?
    var manualHost: String?
}

struct ConnectView: View {
    @EnvironmentObject var connection: PadConnectionManager
    @EnvironmentObject var input: TabletInputController
    @AppStorage("dimDuringSession") private var dim = true
    @AppStorage("sessionBrightness") private var sessionBrightness = 0.15
    @State private var manualHost = ""
    @State private var manualMacID = ""
    @State private var pairing: PairingRequest?
    @State private var showCalibration = false
    @State private var deviceName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let msg = connection.message {
                    messageBanner(msg)
                }
                if connection.state == .paused {
                    pausedCard
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        usbCard
                        wifiCard
                    }
                    VStack(spacing: 20) {
                        pencilCard
                        settingsCard
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $pairing) { req in
            PairingSheet(request: req)
                .environmentObject(connection)
        }
        .fullScreenCover(isPresented: $showCalibration) {
            CalibrationView()
                .environmentObject(input)
        }
        .onAppear {
            deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? ""
            input.refreshScreenSize()
        }
    }

    // MARK: - Intestazione

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPad Graphic Tablet")
                .font(.system(size: 34, weight: .semibold))
            HStack(spacing: 8) {
                Dot(color: stateColor)
                Text(stateText).foregroundStyle(PadTheme.secondary)
            }
        }
    }

    private var stateColor: Color {
        switch connection.state {
        case .connected(let link, _): return link.padColor
        case .connecting: return PadTheme.warn
        case .failed: return PadTheme.accent
        case .paused: return PadTheme.tertiary
        case .idle: return connection.usbListening ? PadTheme.ok.opacity(0.6) : PadTheme.tertiary
        }
    }

    private var stateText: String {
        switch connection.state {
        case .idle: return "Pronto: collega il cavo oppure scegli un Mac in Wi-Fi"
        case .paused: return "In pausa"
        case .connecting(let name): return "Connessione a \(name)…"
        case .connected(let link, let name): return "Collegato a \(name) via \(link.rawValue)"
        case .failed(let why): return why
        }
    }

    private func messageBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { connection.message = nil } label: { Image(systemName: "xmark") }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(PadTheme.warn.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PadTheme.warn.opacity(0.4)))
    }

    private var pausedCard: some View {
        PadCard("Sessione in pausa") {
            Text("Mentre l'app è in pausa il Mac non può ricollegarsi, nemmeno via cavo.")
                .foregroundStyle(PadTheme.secondary)
            Button { connection.resume() } label: {
                Label("Riprendi", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PadTheme.accent)
            .controlSize(.large)
        }
    }

    // MARK: - USB

    private var usbCard: some View {
        PadCard("USB") {
            HStack(spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 28))
                    .foregroundStyle(connection.usbListening ? PadTheme.ok : PadTheme.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.usbListening ? "Pronto per il cavo" : "Non attivo")
                        .font(.headline)
                    Text("Collega l'iPad al Mac con il cavo: l'app sul Mac si connette da sola. Alla prima connessione l'iPad deve aver scelto \"Autorizza\" questo computer.")
                        .font(.callout)
                        .foregroundStyle(PadTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Wi-Fi

    private var wifiCard: some View {
        PadCard("Wi-Fi") {
            if connection.discovered.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Ricerca dei Mac sulla rete…").foregroundStyle(PadTheme.secondary)
                }
            }
            ForEach(connection.discovered) { mac in
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mac.name).font(.body.weight(.medium))
                        Text(mac.isPaired ? "Associato" : (mac.pairingEndpoint != nil ? "In attesa del codice" : "Non associato"))
                            .font(.caption)
                            .foregroundStyle(mac.isPaired ? PadTheme.ok : PadTheme.secondary)
                    }
                    Spacer()
                    if mac.isPaired, mac.endpoint != nil {
                        Button("Connetti") { connection.connect(to: mac) }
                            .buttonStyle(.borderedProminent).tint(PadTheme.accent)
                    } else {
                        Button("Associa…") {
                            pairing = PairingRequest(macName: mac.name, endpoint: mac.pairingEndpoint, manualHost: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().overlay(PadTheme.stroke)

            Text("Indirizzo IP manuale").font(.subheadline.weight(.medium))
            HStack {
                TextField("es. 192.168.1.20", text: $manualHost)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                if !connection.paired.isEmpty {
                    Picker("Mac", selection: $manualMacID) {
                        ForEach(connection.paired) { p in Text(p.name).tag(p.id) }
                    }
                    .onAppear { if manualMacID.isEmpty { manualMacID = connection.paired.first?.id ?? "" } }
                    Button("Connetti") { connection.connectManual(host: manualHost, macID: manualMacID) }
                        .buttonStyle(.bordered)
                        .disabled(manualHost.isEmpty || manualMacID.isEmpty)
                }
                Button("Associa…") {
                    pairing = PairingRequest(macName: manualHost, endpoint: nil, manualHost: manualHost)
                }
                .buttonStyle(.bordered)
                .disabled(manualHost.isEmpty)
            }

            if !connection.paired.isEmpty {
                Divider().overlay(PadTheme.stroke)
                Text("Mac associati").font(.subheadline.weight(.medium))
                ForEach(connection.paired) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Button(role: .destructive) { connection.forget(p) } label: { Text("Dimentica") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: - Pencil

    private var pencilCard: some View {
        PadCard("Apple Pencil") {
            Text("Le funzioni si attivano solo quando vengono rilevate davvero: prova a toccare, sollevare la penna sopra lo schermo, fare doppio tocco o squeeze.")
                .font(.callout).foregroundStyle(PadTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let caps = input.capabilities
            VStack(alignment: .leading, spacing: 8) {
                capabilityRow("Pressione", caps.contains(.pressure), note: "assente su Apple Pencil USB-C")
                capabilityRow("Inclinazione", caps.contains(.tilt))
                capabilityRow("Hover", caps.contains(.hover), note: "iPad Pro M2+ / Air M2+ con Pencil compatibile")
                capabilityRow("Doppio tocco", caps.contains(.doubleTap), note: "Pencil 2 e Pro")
                capabilityRow("Squeeze", caps.contains(.squeeze), note: caps.contains(.osSupportsSqueeze) ? "Pencil Pro" : "richiede iPadOS 17.5")
                capabilityRow("Rotazione", caps.contains(.roll), note: "Pencil Pro")
            }
            HStack {
                Button { showCalibration = true } label: {
                    Label(input.calibration.isIdentity ? "Calibra" : "Ricalibra", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                if !input.calibration.isIdentity {
                    Label("Calibrata", systemImage: "checkmark.circle.fill").foregroundStyle(PadTheme.ok).font(.caption)
                }
            }
        }
    }

    private func capabilityRow(_ title: String, _ on: Bool, note: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(on ? PadTheme.ok : PadTheme.tertiary)
            Text(title)
            Spacer()
            if !on, let note { Text(note).font(.caption).foregroundStyle(PadTheme.tertiary) }
        }
    }

    // MARK: - Impostazioni

    private var settingsCard: some View {
        PadCard("Impostazioni") {
            Toggle("Riconnessione automatica", isOn: $connection.autoReconnect)
            Toggle("Riduci la luminosità in sessione", isOn: $dim)
            if dim {
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $sessionBrightness, in: 0...0.6)
                    Image(systemName: "sun.max")
                }
            }
            Toggle("Mostra un punto dove si trova la penna", isOn: $input.showPenDot)
            HStack {
                Text("Nome di questo iPad")
                TextField(UIDevice.current.name, text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { input.setDeviceName(deviceName) }
            }
            Text("Lo schermo resta nero durante l'uso ma l'app deve restare in primo piano: iPadOS sospende le app in background e spegnere il display interrompe la Pencil. Per evitare uscite accidentali puoi usare Accesso Guidato (Impostazioni → Accessibilità).")
                .font(.caption).foregroundStyle(PadTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(PadTheme.accent)
    }
}

/// Inserimento del codice di associazione mostrato dal Mac.
struct PairingSheet: View {
    let request: PairingRequest
    @EnvironmentObject var connection: PadConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text("Associa \(request.macName)").font(.title2.weight(.semibold))
            Text("Sul Mac apri iPad Graphic Tablet → Connessione → \"Associa un iPad con codice\" e inserisci qui le 6 cifre.")
                .multilineTextAlignment(.center)
                .foregroundStyle(PadTheme.secondary)
            TextField("000000", text: $pin)
                .keyboardType(.numberPad)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($focused)
                .frame(width: 260)
                .onChange(of: pin) { _, v in pin = String(v.filter(\.isNumber).prefix(6)) }
            HStack {
                Button("Annulla") { dismiss() }.buttonStyle(.bordered)
                Button("Associa") {
                    connection.pair(macName: request.macName, pairingEndpoint: request.endpoint,
                                    manualHost: request.manualHost, pin: pin)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(PadTheme.accent)
                .disabled(pin.count != 6)
            }
        }
        .padding(40)
        .onAppear { focused = true }
    }
}
