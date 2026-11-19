//
//  CalibrationView.swift
//  iPad Graphic Tablet — iPad
//
//  Calibrazione a 4 bersagli: tocca il centro di ogni mirino con la Pencil.
//

import SwiftUI
import UIKit

struct CalibrationView: View {
    @EnvironmentObject var input: TabletInputController
    @Environment(\.dismiss) private var dismiss
    @State private var measured: [CGPoint] = []
    @State private var result: Calibration?

    private var targets: [CGPoint] { Calibration.targets }
    private var currentIndex: Int { measured.count }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                CalibrationCapture { p in
                    guard result == nil, measured.count < targets.count else { return }
                    measured.append(p)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if measured.count == targets.count {
                        result = Calibration.fit(measured: measured, expected: targets) ?? .identity
                    }
                }

                if currentIndex < targets.count, result == nil {
                    Crosshair()
                        .position(x: targets[currentIndex].x * geo.size.width,
                                  y: targets[currentIndex].y * geo.size.height)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 14) {
                    Text("Calibrazione Apple Pencil").font(.title2.weight(.semibold))
                    if let r = result {
                        Text(String(format: "Scala X %.3f · Y %.3f — Offset X %+.3f · Y %+.3f",
                                    r.scaleX, r.scaleY, r.offsetX, r.offsetY))
                            .font(PadTheme.mono(13))
                            .foregroundStyle(PadTheme.secondary)
                        HStack {
                            Button("Ripeti") { measured = []; result = nil }.buttonStyle(.bordered)
                            Button("Salva") {
                                input.calibration = r
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent).tint(PadTheme.accent)
                        }
                    } else {
                        Text("Tocca il centro del mirino con la Pencil (\(currentIndex + 1) di \(targets.count))")
                            .foregroundStyle(PadTheme.secondary)
                    }
                    HStack {
                        Button("Azzera calibrazione") {
                            input.calibration = .identity
                            dismiss()
                        }
                        Button("Chiudi") { dismiss() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PadTheme.secondary)
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        // Mirini e cattura devono condividere lo stesso sistema di coordinate (tutto lo schermo).
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(PadTheme.accent, lineWidth: 1.5).frame(width: 44, height: 44)
            Rectangle().fill(Color.white).frame(width: 60, height: 1)
            Rectangle().fill(Color.white).frame(width: 1, height: 60)
            Circle().fill(PadTheme.accent).frame(width: 4, height: 4)
        }
    }
}

/// Cattura il punto (normalizzato, NON calibrato) in cui la Pencil si solleva.
struct CalibrationCapture: UIViewRepresentable {
    var onPoint: (CGPoint) -> Void

    func makeUIView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onPoint = onPoint
        return v
    }

    func updateUIView(_ v: CaptureView, context: Context) {
        v.onPoint = onPoint
    }

    final class CaptureView: UIView {
        var onPoint: ((CGPoint) -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first(where: { $0.type == .pencil }), bounds.width > 0, bounds.height > 0 else { return }
            let p = t.preciseLocation(in: self)
            onPoint?(CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
        }
    }
}
