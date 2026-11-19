//
//  TabletMacApp.swift
//  iPad Graphic Tablet — Mac
//
//  App nella barra dei menu con finestra principale opzionale.
//  Quando la dashboard è chiusa l'app sparisce dal Dock (policy .accessory)
//  e continua a funzionare dalla barra dei menu.
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.connections.stopAll()
    }
}

@main
struct TabletMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        Window("iPad Graphic Tablet", id: "dashboard") {
            DashboardView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch state.connection.phase {
        case .connected: return state.stats.cursorLocked ? "lock.circle.fill" : "pencil.tip.crop.circle.fill"
        case .waiting: return "pencil.tip.crop.circle"
        case .idle: return "pencil.tip.crop.circle.badge.minus"
        }
    }
}
