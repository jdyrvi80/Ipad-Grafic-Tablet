//
//  ButtonsSettingsView.swift
//  iPad Graphic Tablet — Mac
//
//  Doppio tocco / squeeze della Pencil e scorciatoie del pinch.
//

import SwiftUI

struct ButtonsSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card("Apple Pencil") {
                SettingRow(title: "Doppio tocco", help: "Apple Pencil 2 e Pro. Attivo solo se l'iPad lo rileva.") {
                    ActionEditor(action: state.binding(\.doubleTapAction))
                }
                SettingRow(title: "Squeeze", help: "Apple Pencil Pro con iPadOS 17.5+. Le azioni \"tieni premuto\" durano quanto la pressione.") {
                    ActionEditor(action: state.binding(\.squeezeAction))
                }
            }

            Card("Gesti con le dita") {
                Text("1 dito che scorre: muove il cursore · tocco: clic nel punto toccato · doppio tocco: doppio clic · tocco con 2 dita: clic destro · 2 dita: zoom e spostamento dell'area (vedi Area e monitor → Due dita).")
                    .font(.callout).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingRow(title: "Pinch apri", help: "Solo con Due dita = «Zoom e scorrimento nell'app»: il pinch invia una scorciatoia (i veri gesti di zoom del trackpad non sono generabili con API pubbliche).") {
                    ActionEditor(action: state.binding(\.pinchOpenAction))
                }
                SettingRow(title: "Pinch chiudi") {
                    ActionEditor(action: state.binding(\.pinchCloseAction))
                }
            }
        }
    }
}

struct ActionEditor: View {
    @Binding var action: ButtonAction

    private enum Kind: String, CaseIterable, Identifiable {
        case shortcut = "Scorciatoia"
        case hold = "Tieni premuto"
        case lock = "Blocca cursore"
        case precision = "Precisione"
        case eraser = "Penna ↔ gomma"
        case none = "Nessuna"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch action {
        case .shortcut: return .shortcut
        case .holdKey: return .hold
        case .toggleCursorLock: return .lock
        case .togglePrecision: return .precision
        case .toggleEraser: return .eraser
        case .nextMode, .nextProfile, .none: return .none
        }
    }

    private var combo: KeyCombo? {
        switch action {
        case .shortcut(let c), .holdKey(let c): return c
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { kind }, set: { setKind($0) })) {
                ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .labelsHidden()
            .frame(width: 160)
            if combo != nil {
                ShortcutRecorder(combo: Binding(
                    get: { combo ?? KeyCombo() },
                    set: { newCombo in
                        if case .holdKey = action { action = .holdKey(newCombo) } else { action = .shortcut(newCombo) }
                    }))
                    .frame(width: 170, height: 26)
            }
        }
    }

    private func setKind(_ k: Kind) {
        let c = combo ?? KeyCombo()
        switch k {
        case .shortcut: action = .shortcut(c)
        case .hold: action = .holdKey(c)
        case .lock: action = .toggleCursorLock
        case .precision: action = .togglePrecision
        case .eraser: action = .toggleEraser
        case .none: action = .none
        }
    }
}
