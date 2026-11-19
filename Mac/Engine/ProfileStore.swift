//
//  ProfileStore.swift
//  iPad Graphic Tablet — Mac
//
//  Salvataggio dei profili in JSON:
//  ~/Library/Application Support/iPadGraphicTablet/profiles.json
//

import Foundation

final class ProfileStore {
    let directory: URL
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("iPadGraphicTablet", isDirectory: true)
        fileURL = directory.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Carica i profili; aggiunge eventuali preset mancanti.
    func load() -> [TabletProfile] {
        var profiles: [TabletProfile] = []
        if let data = try? Data(contentsOf: fileURL) {
            do {
                profiles = try JSONDecoder().decode([TabletProfile].self, from: data)
            } catch {
                // File di una versione incompatibile: si conserva una copia e si riparte dai preset.
                let backup = directory.appendingPathComponent("profiles-backup-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: backup)
                tlog.warn("Profili non leggibili (\(error)); copia salvata in \(backup.lastPathComponent)")
            }
        }
        for preset in ProfilePresets.all where !profiles.contains(where: { $0.id == preset.id }) {
            profiles.append(preset)
        }
        return profiles
    }

    func save(_ profiles: [TabletProfile]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            tlog.error("Salvataggio profili fallito: \(error)")
        }
    }

    func export(_ profiles: [TabletProfile], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }

    func importProfiles(from url: URL) throws -> [TabletProfile] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TabletProfile].self, from: data)
    }
}
