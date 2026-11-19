//
//  SystemActions.swift
//  iPad Graphic Tablet — Mac
//
//  Azioni di sistema dei gesti del trackpad, con sole API pubbliche:
//  Mission Control, Exposé app e Mostra scrivania aprono l'app Mission Control
//  (con l'argomento "2" o "1"); Launchpad / App apre l'app di sistema.
//  Gli Spaces, avanti/indietro e Ricerca usano le scorciatoie da tastiera di macOS.
//

import AppKit

enum SystemActions {
    private static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    static func missionControl() { openMissionControl(arguments: []) }
    static func appExpose() { openMissionControl(arguments: ["2"]) }
    static func showDesktop() { openMissionControl(arguments: ["1"]) }

    /// Launchpad (fino a macOS 15) oppure App (macOS 26).
    static func launchpad() {
        let candidates = ["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            tlog.warn("Trackpad: Launchpad/App non trovato")
            return
        }
        open(URL(fileURLWithPath: path), arguments: [])
    }

    private static func openMissionControl(arguments: [String]) {
        open(missionControlURL, arguments: arguments)
    }

    private static func open(_ url: URL, arguments: [String]) {
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = arguments
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { tlog.warn("Trackpad: apertura di \(url.lastPathComponent) non riuscita: \(error.localizedDescription)") }
            }
        }
    }
}
