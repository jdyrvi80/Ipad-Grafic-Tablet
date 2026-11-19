//
//  TrackpadSettingsView.swift
//  iPad Graphic Tablet — Mac
//
//  Modalità Trackpad: le opzioni di Impostazioni di Sistema → Trackpad che si possono
//  riprodurre con API pubbliche, con gli stessi nomi. Le dita a tre e quattro funzionano
//  anche in modalità Display.
//

import SwiftUI

struct TrackpadSettingsView: View {
    @EnvironmentObject var state: AppState

    private var profile: TabletProfile { state.activeProfile }
    private var isTrackpad: Bool { profile.mode == .touchpad }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeCard
            pointAndClick
            scrollAndZoom
            moreGestures
            limits
        }
    }

    // MARK: - Modalità

    private var modeCard: some View {
        Card {
            SettingRow(title: "Usa l'iPad come trackpad",
                       help: "In modalità Trackpad l'iPad non mostra lo schermo: è una superficie per le dita, e la Pencil funziona come una tavoletta sull'intero monitor. Puoi cambiare modalità anche dal menu ☰ dell'iPad.") {
                Picker("", selection: Binding(get: { state.activeProfile.mode }, set: { state.setMode($0) })) {
                    ForEach(TabletMode.available) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    // MARK: - Punta e clic

    private var pointAndClick: some View {
        Card("Punta e clic") {
            SettingRow(title: "Velocità di puntamento") {
                ValueSlider(value: state.binding(\.touchpadSpeed), range: 0.3...5,
                            format: { "×\(String(format: "%.1f", $0))" })
            }
            SettingRow(title: "Tocca per fare clic",
                       help: "Sempre attivo: l'iPad non ha un tasto fisico da premere. Doppio tocco = doppio clic.") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
            SettingRow(title: "Clic secondario") {
                Picker("", selection: state.binding(\.trackpad.secondaryClick)) {
                    ForEach(SecondaryClickMode.allCases) { m in Text(m.title).tag(m) }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            SettingRow(title: "Ricerca e rilevatori dati",
                       help: "Tocca con tre dita sulla parola sotto il cursore (⌃⌘D).") {
                Toggle("", isOn: state.binding(\.trackpad.lookUpThreeFingerTap)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            SettingRow(title: "Trascina tenendo premuto",
                       help: "Tieni il dito fermo un attimo, poi muovilo: l'oggetto si trascina finché non sollevi il dito.") {
                Toggle("", isOn: state.binding(\.trackpad.holdToDrag)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            SettingRow(title: "Trascinamento con tre dita",
                       help: "Come l'opzione di Accessibilità di macOS. Se è attivo, i gesti a tre dita qui sotto usano quattro dita.") {
                Toggle("", isOn: state.binding(\.trackpad.threeFingerDrag)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
        }
    }

    // MARK: - Scorri e ingrandisci

    private var scrollAndZoom: some View {
        Card("Scorri e ingrandisci") {
            SettingRow(title: "Scorrimento naturale",
                       help: "Il contenuto segue il movimento delle dita.") {
                Toggle("", isOn: state.binding(\.trackpad.naturalScrolling)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            SettingRow(title: "Inerzia dello scorrimento",
                       help: "Dopo un gesto veloce la pagina continua a scorrere e rallenta da sola.") {
                Toggle("", isOn: state.binding(\.trackpad.scrollInertia)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            SettingRow(title: "Velocità di scorrimento") {
                ValueSlider(value: state.binding(\.scrollSpeed), range: 0.2...4,
                            format: { "×\(String(format: "%.1f", $0))" })
            }
            SettingRow(title: "Ingrandisci o riduci",
                       help: "Pizzica con due dita: invia le scorciatoie di zoom (⌘+ / ⌘−, modificabili in Pencil e gesti).") {
                Toggle("", isOn: state.binding(\.trackpad.pinchToZoom)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
        }
    }

    // MARK: - Altri gesti

    private var moreGestures: some View {
        Card("Altri gesti") {
            SettingRow(title: "Scorri tra le pagine",
                       help: "Scorri a sinistra o a destra: pagina precedente / successiva (⌘[ / ⌘]).") {
                fingersPicker(\.trackpad.swipeBetweenPages)
            }
            SettingRow(title: "Scorri tra le app a tutto schermo",
                       help: "Scorri a sinistra o a destra: Space precedente / successivo (⌃← / ⌃→).") {
                fingersPicker(\.trackpad.swipeBetweenSpaces)
            }
            SettingRow(title: "Mission Control", help: "Scorri verso l'alto.") {
                fingersPicker(\.trackpad.missionControl)
            }
            SettingRow(title: "Exposé app", help: "Scorri verso il basso.") {
                fingersPicker(\.trackpad.appExpose)
            }
            SettingRow(title: "Launchpad / App", help: "Pizzica con il pollice e tre dita.") {
                Toggle("", isOn: state.binding(\.trackpad.launchpad)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            SettingRow(title: "Mostra la scrivania", help: "Allarga il pollice e tre dita.") {
                Toggle("", isOn: state.binding(\.trackpad.showDesktop)).labelsHidden().toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            if conflictText != nil {
                Label(conflictText ?? "", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Per i gesti a quattro dita disattiva sull'iPad Impostazioni → Multitasking e gesti → Gesti con quattro e cinque dita, altrimenti iPadOS li usa per sé.")
                .font(.caption).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fingersPicker(_ keyPath: WritableKeyPath<TabletProfile, GestureFingers>) -> some View {
        Picker("", selection: state.binding(keyPath)) {
            ForEach(GestureFingers.allCases) { f in Text(f.title).tag(f) }
        }
        .labelsHidden()
        .frame(width: 160)
    }

    /// Avviso quando due gesti usano lo stesso movimento con le stesse dita.
    private var conflictText: String? {
        let t = profile.trackpad
        if t.swipeBetweenPages != .off && t.swipeBetweenPages == t.swipeBetweenSpaces {
            return "«Scorri tra le pagine» e «Scorri tra le app a tutto schermo» usano le stesse dita: vince lo scorrimento tra le app."
        }
        if t.threeFingerDrag && (t.swipeBetweenPages == .three || t.swipeBetweenSpaces == .three
                                 || t.missionControl == .three || t.appExpose == .three) {
            return "Con il trascinamento a tre dita attivo, i gesti impostati su tre dita non funzionano: scegli quattro dita."
        }
        return nil
    }

    // MARK: - Limiti

    private var limits: some View {
        Card("Non riproducibili") {
            Text("Clic con pressione (Force Click), Smart zoom, Ruota con due dita e Centro Notifiche dal bordo usano eventi del trackpad che macOS non permette di generare con API pubbliche: per questo non ci sono. Lo zoom con il pizzico usa le scorciatoie dell'app attiva.")
                .font(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
