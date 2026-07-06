//
//  WebExtensionPermissionStore.swift
//  Searxly
//
//  Persists, per extension, the host match-patterns and API permissions the user has granted. Kept in its
//  own resilient file (the password-vault / userscript lesson) so a parse failure can never block the
//  browser. Default state is EMPTY = default-deny: an extension is granted nothing until explicitly
//  approved. (The approval UI is Phase 3; Phase 2 records grants and re-applies them on reload.)
//

import Foundation
import os

/// What the user has granted a single extension.
struct WebExtensionGrant: Codable, Equatable {
    var hosts: [String] = []        // match-pattern strings, e.g. "*://*.example.com/*"
    var permissions: [String] = []  // WKWebExtension.Permission raw values, e.g. "tabs"
}

enum WebExtensionPermissionStore {
    private static let fileName = "WebExtensionGrants.json"

    static func fileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Searxly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func loadAll() -> [String: WebExtensionGrant] {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [:] }
        do {
            return try JSONDecoder().decode([String: WebExtensionGrant].self, from: data)
        } catch {
            Log.web.error("WebExtensionPermissionStore: failed to load — \(String(describing: error))")
            return [:]
        }
    }

    static func grant(for id: String) -> WebExtensionGrant? {
        loadAll()[id]
    }

    static func setGrant(_ grant: WebExtensionGrant, for id: String) {
        var all = loadAll()
        all[id] = grant
        saveAll(all)
    }

    static func clear(id: String) {
        var all = loadAll()
        all.removeValue(forKey: id)
        saveAll(all)
    }

    private static func saveAll(_ all: [String: WebExtensionGrant]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: fileURL(), options: [.atomic])
        } catch {
            Log.web.error("WebExtensionPermissionStore: failed to save — \(String(describing: error))")
        }
    }
}
