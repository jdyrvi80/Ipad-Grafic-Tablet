//
//  MappingSettingsView.swift
//  iPad Graphic Tablet — Mac
//
//  Modalità Display: monitor, area mostrata sull'iPad, trasmissione e gesti.
//

import SwiftUI

struct MappingSettingsView: View {
    @EnvironmentObject var state: AppState

    private var profile: TabletProfile { state.activeProfile }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayModeCard()

            Card("Dita") {
                SettingRow(title: "Velocità del cursore (un dito)",
                           help: "Come la velocità di un trackpad: i movimenti rapidi coprono più spazio.") {
                    ValueSlider(value: state.binding(\.touchpadSpeed), range: 0.3...5,
                                format: { "×\(String(format: "%.1f", $0))" })
                }
                if profile.displayGestures == .app {
                    SettingRow(title: "Velocità di scorrimento (due dita)") {
                        ValueSlider(value: state.binding(\.scrollSpeed), range: 0.2...4,
                                    format: { "×\(String(format: "%.1f", $0))" })
                    }
                }
            }
        }
    }
}
