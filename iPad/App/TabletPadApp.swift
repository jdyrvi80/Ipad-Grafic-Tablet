//
//  TabletPadApp.swift
//  iPad Graphic Tablet — iPad
//

import SwiftUI
import UIKit

final class PadAppDelegate: NSObject, UIApplicationDelegate {
    /// Orientamenti consentiti: durante la sessione si blocca quello corrente.
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PadAppDelegate.orientationLock
    }
}

@main
struct TabletPadApp: App {
    @UIApplicationDelegateAdaptor(PadAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection: PadConnectionManager
    @StateObject private var input: TabletInputController

    init() {
        let connection = PadConnectionManager()
        _connection = StateObject(wrappedValue: connection)
        _input = StateObject(wrappedValue: TabletInputController(connection: connection))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connection)
                .environmentObject(input)
                .preferredColorScheme(.dark)
                .onAppear { connection.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.applicationBecameActive() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var connection: PadConnectionManager

    private var isConnected: Bool {
        if case .connected = connection.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isConnected {
                SessionView()
                    .transition(.opacity)
            } else {
                ConnectView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isConnected)
    }
}

/// Controllo di schermo, luminosità e orientamento durante la sessione.
enum ScreenControl {
    private static var savedBrightness: CGFloat?

    static var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
    }

    static func enterSession(dim: Bool, level: Double) {
        // Lo schermo non deve andare in stop: la Pencil smetterebbe di essere letta.
        UIApplication.shared.isIdleTimerDisabled = true
        if dim, let screen = windowScene?.screen {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = CGFloat(min(max(level, 0), 1))
        }
    }

    static func exitSession() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let b = savedBrightness, let screen = windowScene?.screen {
            screen.brightness = b
        }
        savedBrightness = nil
    }

    /// In modalità Display l'immagine deve essere ben visibile: luminosità originale.
    static func restoreBrightness() {
        if let b = savedBrightness, let screen = windowScene?.screen {
            screen.brightness = b
        }
        savedBrightness = nil
    }

    static func lockCurrentOrientation() {
        guard let scene = windowScene else { return }
        let mask: UIInterfaceOrientationMask
        switch scene.interfaceOrientation {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: mask = .all
        }
        setLock(mask, scene: scene)
    }

    static func unlockOrientation() {
        guard let scene = windowScene else { return }
        setLock(.all, scene: scene)
    }

    private static func setLock(_ mask: UIInterfaceOrientationMask, scene: UIWindowScene) {
        PadAppDelegate.orientationLock = mask
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
