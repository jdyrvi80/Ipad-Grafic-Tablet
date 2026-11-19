//
//  PermissionManager.swift
//  iPad Graphic Tablet — Mac
//
//  Permessi macOS. Per generare eventi di penna/mouse/tastiera serve il
//  permesso "Accessibilità" (Privacy e sicurezza → Accessibilità).
//  Viene richiesto SOLO quando un iPad avvia davvero una sessione.
//

import AppKit
import CoreGraphics

enum PermissionManager {

    /// Il processo può inviare eventi sintetici?
    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    /// Mostra la richiesta di sistema (una sola volta per avvio dell'app).
    @discardableResult
    static func requestPostEvents() -> Bool {
        CGRequestPostEventAccess()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Mostra l'app nel Finder: da lì si trascina nell'elenco Accessibilità.
    /// Utile con le build di Xcode, che stanno in una cartella nascosta (DerivedData).
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}
