//
//  UserScriptStore.swift
//  Searxly
//
//  On-disk persistence for Lane B userscripts. Deliberately isolated in its own resilient file
//  (`UserScripts.json`) rather than folded into the encrypted AppData.json schema — the same lesson
//  learned with the password vault: feature data that the user edits often gets its own file so a parse
//  failure can never corrupt or block core browser state.
//

import Foundation
import os

/// Reads/writes the userscript list. The file is tiny (a handful of small scripts), so synchronous I/O
/// from the main actor is acceptable here, exactly as Persistence does for AppData.json.
enum UserScriptStore {

    private static let fileName = "UserScripts.json"

    /// `~/Library/Application Support/Searxly/UserScripts.json`. Same directory the rest of the app uses.
    static func fileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("Searxly", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent(fileName)
    }

    static func load() -> [UserScript] {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([UserScript].self, from: data)
        } catch {
            // Non-fatal: a corrupt file disables userscripts this session but never blocks the browser.
            Log.web.error("UserScriptStore: failed to load \(fileName, privacy: .public) — \(String(describing: error))")
            return []
        }
    }

    static func save(_ scripts: [UserScript]) {
        let url = fileURL()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(scripts)
            try data.write(to: url, options: [.atomic])
            // Best-effort at-rest protection, matching Persistence.appDataFileURL().
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            Log.web.error("UserScriptStore: failed to save \(fileName, privacy: .public) — \(String(describing: error))")
        }
    }
}
