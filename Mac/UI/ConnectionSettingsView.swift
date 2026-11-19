//
//  ConnectionSettingsView.swift
//  iPad Graphic Tablet — Mac
//
//  USB, Wi-Fi, associazione con PIN e diagnostica del collegamento.
//

import SwiftUI

struct ConnectionSettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var now = Date()

    private var c: ConnectionSnapshot { state.connection }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SafariAccessCard()

            Card("USB") {
                SettingRow(title: "Collegamento via cavo",
                           help: "Usa usbmuxd, lo stesso canale di Finder/Xcode. L'iPad deve aver autorizzato questo Mac (\"Autorizza questo computer\"). Ha la precedenza sul Wi-Fi.") {
                    Toggle("", isOn: $state.usbEnabled).labelsHidden().toggleStyle(.switch)
                }
                infoRow("Stato", c.usbStatus)
                infoRow("iPad collegati via cavo", "\(c.usbDevicesAttached)")
            }
            .tint(Theme.accent)

            Card("Wi-Fi") {
                SettingRow(title: "Collegamento senza fili",
                           help: "Bonjour sulla rete locale, cifrato con TLS 1.2 a chiave condivisa. Nessun server esterno.") {
                    Toggle("", isOn: $state.wifiEnabled).labelsHidden().toggleStyle(.switch)
                }
                infoRow("Stato", c.wifiStatus)
                infoRow("Nome del Mac", state.connections.macName)
                infoRow("Porta", c.wifiPort == 0 ? "—" : "\(c.wifiPort)")
                infoRow("Indirizzi IP", localAddresses().joined(separator: ", "))
            }
            .tint(Theme.accent)

            Card("Associazione Wi-Fi") {
                if let pin = state.pairingPIN, let deadline = state.pairingDeadline {
                    HStack(alignment: .center, spacing: 24) {
                        Text(spaced(pin))
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.text)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inserisci questo codice sull'iPad").font(.headline)
                            Text("Scade tra \(max(0, Int(deadline.timeIntervalSince(now)))) s · dopo 5 tentativi errati la finestra si chiude.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                            Button("Annulla") { state.cancelPairing() }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    Text("Se colleghi l'iPad almeno una volta via cavo, l'associazione Wi-Fi avviene in automatico. In alternativa genera un codice da inserire sull'iPad.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { state.beginPairing() } label: { Label("Associa un iPad con codice", systemImage: "number") }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(!state.wifiEnabled)
                        Button(role: .destructive) { state.revokePairings() } label: {
                            Label("Revoca tutte le associazioni", systemImage: "xmark.shield")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Card("Permessi di rete") {
                Text("Su macOS 15 e successivi la prima volta il sistema chiede il permesso \"Rete locale\": senza di esso gli iPad in Wi-Fi non trovano il Mac.")
                    .font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Apri Privacy → Rete locale") { PermissionManager.openLocalNetworkSettings() }
                    .buttonStyle(.bordered)
            }
        }
        .task {
            // Aggiorna il conto alla rovescia del PIN una volta al secondo.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).font(Theme.mono(12)).textSelection(.enabled)
        }
    }

    private func spaced(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return String(pin.prefix(3)) + " " + String(pin.suffix(3))
    }

    private func localAddresses() -> [String] {
        let list = NetworkInfo.ipv4Addresses().map { "\($0.ip) (\($0.interface))" }
        return list.isEmpty ? ["—"] : list
    }
}

/// Collegamento senza installare app: Safari sull'iPad + IP del Mac.
struct SafariAccessCard: View {
    @EnvironmentObject var state: AppState
    @State private var urls: [String] = []

    var body: some View {
        Card("Safari — senza installare app sull'iPad") {
            SettingRow(title: "Pagina per Safari",
                       help: "L'iPad apre in Safari l'indirizzo qui sotto: pressione, inclinazione e hover arrivano dal browser. Nessuna installazione, nessun account sviluppatore.") {
                Toggle("", isOn: $state.webEnabled).labelsHidden().toggleStyle(.switch)
            }
            if state.webEnabled {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Sull'iPad apri Safari e scrivi").font(.callout).foregroundStyle(Theme.secondary)
                        ForEach(urls, id: \.self) { url in
                            Text(url)
                                .font(Theme.mono(18, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        if urls.isEmpty {
                            Text("Nessuna rete attiva: collega il Mac al Wi-Fi.").foregroundStyle(Theme.warn)
                        }
                        Text("2. Inserisci il codice").font(.callout).foregroundStyle(Theme.secondary)
                        HStack(spacing: 14) {
                            Text(spaced(state.webCode))
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            Button("Nuovo codice") { state.regenerateWebCode() }
                                .buttonStyle(.bordered)
                        }
                        Text("Oppure inquadra il QR con la Fotocamera dell'iPad: apre la pagina con il codice già inserito.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Stato: \(state.connection.webStatus)")
                            .font(Theme.mono(11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    if let first = urls.first, let qr = NetworkInfo.qrCode(for: "\(first)/#code=\(state.webCode)") {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 170, height: 170)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                    }
                }
                Text("Limiti rispetto all'app iPad: niente doppio tocco, squeeze e rotazione della Pencil (Safari non li espone), solo rete locale, traffico non cifrato (l'accesso resta protetto dal codice). Su macOS consenti le connessioni in entrata se il firewall lo chiede.")
                    .font(.caption).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
        .onAppear { urls = state.webURLs }
        .onChange(of: state.webEnabled) { _, _ in urls = state.webURLs }
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}
