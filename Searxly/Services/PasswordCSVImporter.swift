//
//  PasswordCSVImporter.swift
//  Searxly
//
//  Imports logins from the CSV files exported by other password managers / browsers
//  (Chrome, Safari, Firefox, Bitwarden, 1Password, …). Columns are detected by header name, so the
//  same importer handles all of them. Secrets are written through PasswordVaultManager.addEntry, which
//  stores the password in the Keychain (PasswordVaultSecureStore) — they never touch AppData.
//
//  Sandbox-safe: the user picks the file via NSOpenPanel. The CSV holds plaintext passwords, so the
//  import hub reminds the user to securely delete it afterward.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
enum PasswordCSVImporter {
    struct Summary {
        let imported: Int   // newly added logins
        let skipped: Int    // already in the vault (same domain + username)
        let failed: Int     // rows missing a usable url / username / password
        let total: Int      // data rows in the file
    }

    enum Outcome {
        case imported(Summary)
        case unrecognizedColumns   // no url/password columns found in the header
        case noRows                // header only, or empty file
        case unreadable            // couldn't read the file
    }

    /// Header synonyms across the common exporters (compared lowercased/trimmed).
    private static let urlKeys      = ["url", "uri", "website", "web site", "login_uri", "login uri", "site"]
    private static let usernameKeys = ["username", "user name", "login_username", "login", "email", "e-mail", "account", "user"]
    private static let passwordKeys = ["password", "login_password", "pass", "pwd"]
    private static let notesKeys    = ["notes", "note", "comment", "comments", "extra"]
    private static let nameKeys     = ["name", "title", "item name"]

    /// Shows the open panel and returns the chosen CSV file (main thread). nil if cancelled.
    static func pickCSVFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Passwords"
        panel.message = "Choose a passwords CSV exported from your browser or password manager."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .text, .plainText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Reads + parses the CSV off the main thread, then writes new logins through the Keychain vault
    /// (de-duplicated by normalized domain + username).
    static func importPasswords(from url: URL) async -> Outcome {
        let rows: [[String]] = await Task.detached(priority: .userInitiated) {
            // NSOpenPanel URLs can be security-scoped in the sandbox; without this the read can fail.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = readText(at: url) else { return [] }
            return parseCSV(text)
        }.value

        guard let header = rows.first else { return .unreadable }
        guard rows.count >= 2 else { return .noRows }

        let lowerHeader = header.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let urlIdx = firstIndex(in: lowerHeader, anyOf: urlKeys),
              let passIdx = firstIndex(in: lowerHeader, anyOf: passwordKeys) else {
            return .unrecognizedColumns
        }
        let userIdx  = firstIndex(in: lowerHeader, anyOf: usernameKeys)
        let notesIdx = firstIndex(in: lowerHeader, anyOf: notesKeys)
        let nameIdx  = firstIndex(in: lowerHeader, anyOf: nameKeys)

        let dataRows = rows.dropFirst()
        var imported = 0, skipped = 0, failed = 0

        for row in dataRows {
            // Skip fully blank lines that some exporters leave between records.
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }

            let urlField = field(row, urlIdx)
            let nameField = nameIdx.map { field(row, $0) } ?? ""
            let domain = PasswordVaultManager.normalizeDomain(urlField.isEmpty ? nameField : urlField)
            let username = userIdx.map { field(row, $0) } ?? ""
            let password = field(row, passIdx)
            let notes = notesIdx.map { field(row, $0) }?.nilIfBlank

            guard !domain.isEmpty, !username.isEmpty, !password.isEmpty else { failed += 1; continue }

            // Already in the vault? (same normalized domain + same username, case-insensitive)
            let dupe = PasswordVaultManager.shared.entries(forDomain: domain)
                .contains { $0.username.compare(username, options: .caseInsensitive) == .orderedSame }
            if dupe { skipped += 1; continue }

            if PasswordVaultManager.shared.addEntry(domain: domain, username: username, password: password, notes: notes) != nil {
                imported += 1
            } else {
                failed += 1
            }
        }

        return .imported(Summary(imported: imported, skipped: skipped, failed: failed, total: dataRows.count))
    }

    // MARK: - CSV parsing (RFC 4180-ish: quoted fields, escaped quotes, commas/newlines in quotes)

    nonisolated static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")   // escaped quote ("")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(c)
                    i += 1
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true; i += 1
                case ",":
                    record.append(field); field = ""; i += 1
                case "\r":
                    i += 1   // swallow CR (handle CRLF)
                case "\n":
                    record.append(field); field = ""
                    rows.append(record); record = []
                    i += 1
                default:
                    field.append(c); i += 1
                }
            }
        }
        // Flush the final field/record when the file doesn't end with a newline.
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            rows.append(record)
        }
        return rows
    }

    // MARK: - Helpers

    private static func firstIndex(in header: [String], anyOf keys: [String]) -> Int? {
        for key in keys {
            if let idx = header.firstIndex(of: key) { return idx }
        }
        return nil
    }

    private static func field(_ row: [String], _ index: Int) -> String {
        guard index >= 0, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func readText(at url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        if let data = try? Data(contentsOf: url) {
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
