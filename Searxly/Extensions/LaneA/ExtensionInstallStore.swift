//
//  ExtensionInstallStore.swift
//  Searxly
//
//  Tracks which Lane A extensions are installed, so they survive app restarts. Each record points at a
//  package directory under Application Support. Own resilient file (the password-vault / userscript
//  lesson). 15.0-safe (pure file I/O) so launch bootstrap can consult it without touching 15.4 types.
//

import Foundation
import os

struct InstalledExtensionRecord: Codable, Identifiable {
    /// Stable extension id (also used as `context.uniqueIdentifier` and the permission-store key).
    let id: String
    var displayName: String
    /// Absolute path to the package directory (contains manifest.json).
    var directory: String
    var builtInDemo: Bool
}

enum ExtensionInstallStore {
    private static let fileName = "ExtensionInstalls.json"

    static func searxlyAppSupport() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Searxly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Searxly/Extensions` — where installed packages live.
    static func extensionsDirectory() -> URL {
        let dir = searxlyAppSupport().appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL() -> URL {
        searxlyAppSupport().appendingPathComponent(fileName)
    }

    static func all() -> [InstalledExtensionRecord] {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([InstalledExtensionRecord].self, from: data)
        } catch {
            Log.web.error("ExtensionInstallStore: failed to load — \(String(describing: error))")
            return []
        }
    }

    static func hasInstalled() -> Bool { !all().isEmpty }

    static func add(_ record: InstalledExtensionRecord) {
        var records = all().filter { $0.id != record.id }
        records.append(record)
        save(records)
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    private static func save(_ records: [InstalledExtensionRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: fileURL(), options: [.atomic])
        } catch {
            Log.web.error("ExtensionInstallStore: failed to save — \(String(describing: error))")
        }
    }
}
