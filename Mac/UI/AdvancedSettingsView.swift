//
//  AdvancedSettingsView.swift
//  iPad Graphic Tablet — Mac
//

import SwiftUI
import AppKit

struct AdvancedSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card("Generazione dell'input") {
                info("Backend", state.engine.backendName)
                info("Permesso Accessibilità", state.stats.canPostEvents ? "concesso" : "mancante")
                info("Layout tastiera", KeyboardLayoutResolver.shared.layoutName)
                HStack {
                    Button("Apri Privacy → Accessibilità") { PermissionManager.openAccessibilitySettings() }
                    Button("Rileggi layout tastiera") { KeyboardLayoutResolver.shared.refresh() }
                }
                .buttonStyle(.bordered)
            }

            Card("Cosa è reale e cosa no") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Pressione, inclinazione e rotazione arrivano alle app come veri eventi tavoletta macOS (NSEvent subtype tabletPoint + prossimità). Verificalo nella sezione Test.")
                    bullet("Il Mac non vede un dispositivo HID \"Wacom\": app che richiedono il driver Wacom per abilitare la pressione (es. Illustrator) potrebbero ignorarla. Soluzione documentata: installare il driver Wacom gratuito, anche senza tavoletta.")
                    bullet("I gesti nativi del trackpad (pinch/rotazione di sistema) non sono generabili con API pubbliche: il pinch viene tradotto in scorciatoie.")
                    bullet("Funzioni come hover, squeeze e rotazione si attivano solo dopo che l'iPad le ha effettivamente rilevate.")
                }
                .font(.callout)
                .foregroundStyle(Theme.secondary)
            }

            Card("Dati") {
                info("Cartella profili", state.store.directory.path)
                HStack {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.store.directory]) }
                    Button("Esci da iPad Graphic Tablet") { NSApp.terminate(nil) }
                }
                .buttonStyle(.bordered)
                Text("Nessun dato viene inviato a server esterni. La comunicazione avviene solo tra questo Mac e il tuo iPad.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).font(Theme.mono(12)).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
