//
//  Theme.swift
//  iPad Graphic Tablet — Mac
//
//  Stile: fondo nero, testi bianchi, un solo accento rosso, cifre monospaziate,
//  indicatori a punto. Ispirazione Apple / Nothing.
//

import SwiftUI

enum Theme {
    static let background = Color.black
    static let surface = Color(white: 0.07)
    static let surfaceHigh = Color(white: 0.11)
    static let stroke = Color.white.opacity(0.09)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let accent = Color(red: 1.0, green: 0.18, blue: 0.18)
    static let ok = Color(red: 0.25, green: 0.88, blue: 0.48)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.2)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Riquadro con bordo sottile.
struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    let content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(Theme.mono(11, weight: .medium))
                            .tracking(1.5)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }
}

/// Punto di stato.
struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var on = false

    private var currentOpacity: Double {
        guard pulsing else { return 1 }
        return on ? 1 : 0.35
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(currentOpacity)
            .onAppear {
                guard pulsing else { return }
                // (animazione del punto pulsante)
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Valore grande con etichetta (stile strumentazione).
struct Metric: View {
    var label: String
    var value: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.mono(22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Barra orizzontale a segmenti (pressione, livelli).
struct SegmentBar: View {
    var value: Double   // 0…1
    var segments = 24
    var color: Color = Theme.text

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(segmentColor(i))
                    .frame(height: 10)
            }
        }
        .animation(.linear(duration: 0.08), value: value)
    }

    private func segmentColor(_ i: Int) -> Color {
        let position: Double = Double(i) / Double(segments)
        return position < value ? color : Color.white.opacity(0.08)
    }
}

/// Riga etichetta + controllo, usata nelle impostazioni.
struct SettingRow<Control: View>: View {
    var title: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                if let help {
                    Text(help).font(.caption).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 4)
    }
}

/// Slider con valore numerico.
struct ValueSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        HStack(spacing: 10) {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(format(value))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .frame(width: 280)
        .tint(Theme.accent)
    }
}

extension LinkKind {
    var color: Color {
        switch self {
        case .usb: return Theme.ok
        case .wifi: return Color(red: 0.35, green: 0.65, blue: 1)
        case .web: return Color(red: 0.62, green: 0.5, blue: 1)
        }
    }
    var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .web: return "safari"
        }
    }
}
