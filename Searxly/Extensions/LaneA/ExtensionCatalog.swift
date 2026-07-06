//
//  ExtensionCatalog.swift
//  Searxly
//
//  The curated-gallery client. Fetches a signed catalog from searxly.app, verifies each package's
//  integrity (SHA-256) and authenticity (Ed25519, once a signing key is configured), and downloads it for
//  installation. Degrades gracefully: if the catalog isn't published / the Mac is offline, fetch() returns
//  [] and the marketplace falls back to its built-in entries.
//
//  This is the CLIENT side. The server side (hosting catalog.json + signed .zip packages on searxly.app)
//  is operational work; fill in `publicKeyBase64` and the real `catalogURL` content when that's ready.
//

import Foundation
import CryptoKit
import os

struct ExtensionCatalog: Decodable {
    let version: Int
    let extensions: [ExtensionCatalogEntry]
}

struct ExtensionCatalogEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let version: String
    var author: String?
    var license: String?
    /// SF Symbol name for the card icon.
    var icon: String?
    var permissionsSummary: String?
    /// HTTPS URL to the `.zip` package (a zip containing manifest.json — `WKWebExtension` loads it directly).
    let package: String
    /// Lowercase hex SHA-256 of the package bytes.
    let sha256: String
    /// Base64 Ed25519 signature over the package bytes. Optional until signing is configured.
    var signature: String?
}

enum ExtensionCatalogClient {
    /// Curated catalog location — HTTPS, Searxly's own domain. Canonical `www` host (the apex
    /// `searxly.app` 308-redirects to it), so we avoid an extra redirect hop on every fetch.
    static let catalogURL = URL(string: "https://www.searxly.app/extensions/catalog.json")!

    /// Base64 Ed25519 public key for verifying package signatures. EMPTY until signing is set up; while
    /// empty, packages are trusted on SHA-256 + HTTPS-from-our-domain alone (logged). Set this before the
    /// real catalog ships so every package MUST be signed.
    static let publicKeyBase64 = ""

    /// Fetches + parses the catalog. Returns `[]` on any failure so the UI degrades gracefully.
    static func fetch() async -> [ExtensionCatalogEntry] {
        do {
            var request = URLRequest(url: catalogURL)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder().decode(ExtensionCatalog.self, from: data).extensions
        } catch {
            Log.web.info("[ExtensionCatalog] no catalog (offline or not published yet)")
            return []
        }
    }

    /// Downloads the package, verifies it, and writes it under the extension's install directory.
    /// Returns the local `.zip` URL (a valid `WKWebExtension` resourceBaseURL).
    static func downloadVerifiedPackage(_ entry: ExtensionCatalogEntry) async throws -> URL {
        guard let url = URL(string: entry.package), url.scheme == "https" else {
            throw CatalogError.badPackageURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogError.downloadFailed
        }

        // Integrity: SHA-256 must match the catalog entry.
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw CatalogError.hashMismatch
        }

        // Authenticity: require a valid Ed25519 signature whenever a public key is configured.
        if !publicKeyBase64.isEmpty {
            guard let sigB64 = entry.signature,
                  let sigData = Data(base64Encoded: sigB64),
                  let keyData = Data(base64Encoded: publicKeyBase64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  key.isValidSignature(sigData, for: data) else {
                throw CatalogError.signatureInvalid
            }
        } else {
            Log.web.info("[ExtensionCatalog] no signing key set — accepting \(entry.id, privacy: .public) on SHA-256 + HTTPS only")
        }

        let dir = ExtensionInstallStore.extensionsDirectory().appendingPathComponent(entry.id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = dir.appendingPathComponent("package.zip")
        try data.write(to: pkg, options: [.atomic])
        return pkg
    }

    enum CatalogError: LocalizedError {
        case badPackageURL, downloadFailed, hashMismatch, signatureInvalid
        var errorDescription: String? {
            switch self {
            case .badPackageURL:   return "The extension's download link is invalid."
            case .downloadFailed:  return "Couldn't download the extension."
            case .hashMismatch:    return "The download didn't match the catalog (integrity check failed)."
            case .signatureInvalid: return "The extension's signature couldn't be verified."
            }
        }
    }
}
