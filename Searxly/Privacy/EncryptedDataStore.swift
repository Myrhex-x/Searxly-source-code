//
//  EncryptedDataStore.swift
//  Searxly
//
//  Focused store responsible for reading and writing the main AppData.json
//  with optional transparent encryption.
//
//  This file isolates all encryption-related I/O so the rest of the app
//  can remain relatively simple and low-risk.
//

import Foundation
import os
import CryptoKit

enum EncryptedDataStore {

    private static let metadataFileName = "EncryptionMetadata.json"

    // MARK: - In-memory cache (performance)
    //
    // AppData is read + decrypted from disk FAR more often than it changes: every settings toggle,
    // every tab open/close (saveCurrentSession), and the convenience savers (saveBookmarks, saveHistory,
    // saveConfiguration, …) all do a full load → mutate → save round-trip. Without a cache each of those
    // re-reads the whole file off disk and runs an AES-GCM decrypt, and each save() additionally re-read
    // the whole file again just to sniff the encryption magic header.
    //
    // This cache makes the decoded AppData the in-memory source of truth: every save() updates it
    // synchronously, so callers always observe their own writes, and load() never touches disk after the
    // first read. We also cache the encryption-enabled flag and dedup identical writes.
    //
    // DURABILITY: writes remain SYNCHRONOUS — we never debounce/defer the disk write. Deferred writes were
    // previously observed to be lost on quick-quit (history "reverted" bug; see the settings-toggle
    // persistence guidance). We only remove redundant work; we never delay durability.
    private static let cacheLock = NSLock()
    private static var cachedData: AppData?
    private static var cachedEncryptionEnabled: Bool?
    /// SHA-256 of the last *plaintext* JSON actually written to disk. Used to skip redundant identical
    /// writes. We hash plaintext because AES-GCM uses a random nonce, so the ciphertext is never stable.
    private static var lastWrittenJSONHash: Data?

    enum DataLoadResult {
        case success(AppData)
        case missingFile
        case decryptionFailed(DataEncryptor.EncryptionError)
        case decodeFailed(Error)
    }

    // MARK: - Public API (used by Persistence)

    static func loadDetailed() -> DataLoadResult {
        let url = Persistence.appDataFileURL()

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missingFile
        }

        do {
            let rawData = try Data(contentsOf: url)

            if isLikelyEncrypted(rawData) {
                let decrypted = try DataEncryptor.decryptWithStoredKey(rawData)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return .success(try decoder.decode(AppData.self, from: decrypted))
            } else {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return .success(try decoder.decode(AppData.self, from: rawData))
            }
        } catch let error as DataEncryptor.EncryptionError {
            Log.security.error("EncryptedDataStore: CRITICAL — encryption error during load: \(error.localizedDescription, privacy: .public); blocking recovery UI, data not modified")
            notifyRecoveryRequired(for: error)
            return .decryptionFailed(error)
        } catch {
            Log.security.error("EncryptedDataStore: failed to load data — \(error.localizedDescription, privacy: .public); returning defaults")
            backupCorruptFile(at: url)
            return .decodeFailed(error)
        }
    }

    static func load() -> AppData {
        cacheLock.lock()
        if let cached = cachedData {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Cache miss: read + decode from disk (the expensive path we want to do at most once).
        switch loadDetailed() {
        case .success(let data):
            cacheLock.lock()
            // Another thread may have populated the cache (or saved) while we were reading; prefer that.
            let value = cachedData ?? data
            cachedData = value
            cacheLock.unlock()
            return value
        case .missingFile:
            // Safe to cache: an absent file genuinely means "defaults". The first save() will create it.
            cacheLock.lock()
            let value = cachedData ?? AppData()
            cachedData = value
            cacheLock.unlock()
            return value
        case .decryptionFailed, .decodeFailed:
            // Do NOT cache a defaults-on-failure result. A transient decrypt failure drives the recovery
            // UI; caching defaults here (and then saving) could clobber the still-intact encrypted file.
            return AppData()
        }
    }

    static func save(_ appData: AppData) {
        // Update the in-memory source of truth first, so concurrent load()s observe the new value
        // even if the disk write below dedups or fails.
        cacheLock.lock()
        cachedData = appData
        cacheLock.unlock()

        let url = Persistence.appDataFileURL()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(appData)

            // Dedup: skip the encrypt + atomic write when nothing actually changed since the last write.
            let jsonHash = Data(SHA256.hash(data: jsonData))
            cacheLock.lock()
            let unchanged = (jsonHash == lastWrittenJSONHash)
            cacheLock.unlock()
            if unchanged { return }

            if isEncryptionEnabled() {
                if let key = KeychainManager.loadKey() {
                    let encrypted = try DataEncryptor.encrypt(jsonData, using: key)
                    try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
                    // (success logging removed to reduce console spam)
                } else {
                    // CRITICAL: Encryption was requested but we have no key in the Keychain.
                    // Do NOT silently fall back to plaintext — this would defeat the user's explicit choice.
                    Log.security.error("EncryptedDataStore: CRITICAL — encryption enabled but no key in Keychain. Refusing to write plaintext; data NOT saved. Re-enable encryption or restore your recovery key.")
                    // We leave the file untouched rather than risk writing plaintext.
                    // Do not record the hash: no write happened, so a later identical save must retry.
                    return
                }
            } else {
                try jsonData.write(to: url, options: [.atomic, .completeFileProtection])
                // (plaintext success log removed)
            }

            // Record what we actually persisted so the next identical save() can be skipped.
            cacheLock.lock()
            lastWrittenJSONHash = jsonHash
            cacheLock.unlock()
        } catch {
            Log.security.error("EncryptedDataStore: failed to save data — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the in-memory caches so the next load() re-reads from disk. Call after any out-of-band
    /// change to AppData.json (e.g. recovery flows). Backup restore and erase already keep the cache
    /// consistent via save()/eraseLocalData(), but this is the safe escape hatch.
    static func invalidateCaches() {
        cacheLock.lock()
        cachedData = nil
        cachedEncryptionEnabled = nil
        lastWrittenJSONHash = nil
        cacheLock.unlock()
    }

    // MARK: - Encryption Toggle Management (now uses a small unencrypted metadata file next to AppData.json)

    static func isEncryptionEnabled() -> Bool {
        cacheLock.lock()
        if let cached = cachedEncryptionEnabled {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // First read this session — resolve from disk, then cache. The flag only changes via
        // setEncryptionEnabled()/eraseLocalData() (both update the cache), so after this it's stable
        // and save() no longer pays a whole-file read just to sniff the magic header.
        let value = computeEncryptionEnabledFromDisk()
        cacheLock.lock()
        cachedEncryptionEnabled = value
        cacheLock.unlock()
        return value
    }

    private static func computeEncryptionEnabledFromDisk() -> Bool {
        let metadataURL = encryptionMetadataURL()

        // If the main data file looks encrypted, trust the content over missing/broken metadata.
        let mainURL = Persistence.appDataFileURL()
        if FileManager.default.fileExists(atPath: mainURL.path) {
            if let raw = try? Data(contentsOf: mainURL), isLikelyEncrypted(raw) {
                return true
            }
        }

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return false
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            let meta = try decoder.decode(EncryptionMetadata.self, from: data)
            return meta.encryptionEnabled
        } catch {
            Log.security.error("EncryptedDataStore: failed to read encryption metadata — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Enables or disables encryption for future saves.
    /// Writes a small metadata file. Does NOT automatically migrate existing data.
    static func setEncryptionEnabled(_ enabled: Bool) {
        let metadataURL = encryptionMetadataURL()
        let meta = EncryptionMetadata(encryptionEnabled: enabled)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(meta)
            // Use the strongest practical protection for the metadata toggle file
            try data.write(to: metadataURL, options: [.atomic, .completeFileProtection])

            // Keep the in-memory flag in sync, and clear the write-dedup hash: the encryption *state*
            // is part of what's on disk, so the next save() must actually re-write (now (un)encrypted)
            // even if the AppData payload itself is byte-for-byte identical to the last write.
            cacheLock.lock()
            cachedEncryptionEnabled = enabled
            lastWrittenJSONHash = nil
            cacheLock.unlock()

            Log.security.info("EncryptedDataStore: encryption-enabled set to \(enabled, privacy: .public)")
        } catch {
            Log.security.error("EncryptedDataStore: failed to write encryption metadata — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Last-resort reset: erases the local data store so the app can start fresh.
    ///
    /// This is the only way out when the encrypted `AppData.json` cannot be decrypted and the user has
    /// no recovery code or backup — e.g. the Keychain encryption key was orphaned by an app-identity
    /// change (sandbox container / signing / team-ID flip), which makes the on-disk blob permanently
    /// unreadable. The sandbox protects the container from any outside tool, so only the app itself can
    /// remove these files.
    ///
    /// Removes `AppData.json`, the encryption metadata toggle, and any quarantined `AppData.json.broken-*`
    /// copies, then turns encryption off. Browsing history / bookmarks / instances / settings are lost;
    /// the wallet seed (WalletKeychain) and saved passwords (PasswordVaultSecureStore) live in separate
    /// stores and are NOT affected.
    static func eraseLocalData() {
        let fm = FileManager.default
        let appDataURL = Persistence.appDataFileURL()
        let dir = appDataURL.deletingLastPathComponent()

        try? fm.removeItem(at: appDataURL)
        try? fm.removeItem(at: encryptionMetadataURL())

        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("AppData.json.broken-") {
                try? fm.removeItem(at: url)
            }
        }

        // The on-disk files are gone — drop every cache so nothing stale survives the wipe.
        invalidateCaches()

        // Future saves start as plaintext defaults until the user explicitly re-enables encryption.
        setEncryptionEnabled(false)
    }

    // MARK: - Helpers

    private static func encryptionMetadataURL() -> URL {
        let appDir = Persistence.appDataFileURL().deletingLastPathComponent()
        return appDir.appendingPathComponent(metadataFileName)
    }

    /// Exposed as `internal` so `@testable import Searxly` tests can verify format detection.
    static func looksEncrypted(_ data: Data) -> Bool { isLikelyEncrypted(data) }

    private static func isLikelyEncrypted(_ data: Data) -> Bool {
        // Newer format: 4-byte magic "SENC" + 1-byte version + AES-GCM combined (nonce 12 + tag 16 + ≥1 byte)
        // Minimum: 5 header bytes + 29 bytes AES-GCM overhead = 34 bytes.
        if data.count >= 34, data.prefix(4) == Data("SENC".utf8) {
            return true
        }

        // Old format: single version byte (1) followed by raw AES-GCM combined output.
        // AES-GCM combined = 12-byte nonce + 16-byte tag + ≥1 byte ciphertext = 29 bytes minimum.
        // Without this minimum length guard, any file whose first byte happens to be 0x01 would
        // be misidentified as encrypted, causing a decrypt failure and silent data loss.
        if data.count >= 30, data[0] == 1 {
            return true
        }

        return false
    }

    private struct EncryptionMetadata: Codable {
        var encryptionEnabled: Bool
    }

    /// Renames the unreadable AppData.json to AppData.json.broken-<timestamp> (preserves both plaintext and SENC encrypted bytes).
    /// This prevents the common failure mode where a decode error for one sub-section (e.g. a new field in WalletAccount)
    /// causes the entire load to return defaults, and a subsequent partial-save then clobbers all other settings
    /// (SearXNG instances, performance, history, VPN profiles, etc.).
    private static func notifyRecoveryRequired(for error: DataEncryptor.EncryptionError) {
        if Thread.isMainThread {
            EncryptionRecoveryManager.shared.markDecryptionFailed(error)
        } else {
            DispatchQueue.main.async {
                EncryptionRecoveryManager.shared.markDecryptionFailed(error)
            }
        }
    }

    private static func backupCorruptFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("AppData.json.broken-\(ts)")
        do {
            try FileManager.default.moveItem(at: url, to: backupURL)
            Log.security.notice("EncryptedDataStore: backed up unreadable data file to \(backupURL.lastPathComponent, privacy: .public); restore manually after fixing the decode issue")
        } catch {
            Log.security.error("EncryptedDataStore: could not back up corrupt file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
