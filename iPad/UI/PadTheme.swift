//
//  PadTheme.swift
//  iPad Graphic Tablet — iPad
//

import SwiftUI

enum PadTheme {
    static let surface = Color(white: 0.07)
    static let stroke = Color.white.opacity(0.1)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.3)
    static let accent = Color(red: 1.0, green: 0.18, blue: 0.18)
    static let ok = Color(red: 0.25, green: 0.88, blue: 0.48)
    static let wifi = Color(red: 0.35, green: 0.65, blue: 1)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.2)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct PadCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(PadTheme.mono(12, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(PadTheme.secondary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(PadTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(PadTheme.stroke))
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 9
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

extension LinkKind {
    var padColor: Color { self == .usb ? PadTheme.ok : PadTheme.wifi }
    var symbol: String { self == .usb ? "cable.connector" : "wifi" }
}
