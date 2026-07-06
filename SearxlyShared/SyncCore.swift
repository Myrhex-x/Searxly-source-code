//
//  SyncCore.swift
//  SearxlyShared
//
//  Private, server-less sync between the macOS and iOS apps. One device (the "sender") exports
//  its bookmarks + history into an ENCRYPTED bundle and shows a short pairing code; the other
//  device receives the bundle (over AirDrop / Files — never a server, never an account) and
//  enters the code to decrypt and merge. The code is the only secret; the encrypted file carries
//  a random salt, so the same data + code never produces the same ciphertext.
//
//  This is the portable heart shared by both apps: the wire format, the crypto, and the
//  code generation. Each app maps its own bookmark/history model to/from these plain structs.
//

import Foundation
import CryptoKit

// MARK: - Portable payload

public struct SyncBookmark: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let addedAt: Date
    public init(url: String, title: String, addedAt: Date) {
        self.url = url; self.title = title; self.addedAt = addedAt
    }
}

public struct SyncHistoryItem: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let visitedAt: Date
    public init(url: String, title: String, visitedAt: Date) {
        self.url = url; self.title = title; self.visitedAt = visitedAt
    }
}

public struct SyncBundle: Codable, Equatable, Sendable {
    public var bookmarks: [SyncBookmark]
    public var history: [SyncHistoryItem]
    public var exportedAt: Date
    public var deviceName: String
    public init(bookmarks: [SyncBookmark], history: [SyncHistoryItem], exportedAt: Date = .now, deviceName: String) {
        self.bookmarks = bookmarks; self.history = history
        self.exportedAt = exportedAt; self.deviceName = deviceName
    }
}

// MARK: - Crypto + wire format

public enum SyncCrypto {

    public enum SyncError: Error, LocalizedError {
        case badFormat
        case wrongCode
        public var errorDescription: String? {
            switch self {
            case .badFormat: return "This isn't a valid Searxly sync file."
            case .wrongCode: return "That code didn't match. Check it and try again."
            }
        }
    }

    private static let magic = Data("SSYNC".utf8)   // 5 bytes
    private static let version: UInt8 = 1
    private static let saltLength = 16

    /// Encrypts a bundle under a code. Format: magic(5) · version(1) · salt(16) · AES-GCM combined.
    public static func seal(_ bundle: SyncBundle, code: String) throws -> Data {
        let salt = randomBytes(saltLength)
        let key = deriveKey(code: code, salt: salt)
        let plaintext = try JSONEncoder().encode(bundle)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw SyncError.badFormat }
        var out = magic
        out.append(version)
        out.append(salt)
        out.append(combined)
        return out
    }

    /// Decrypts a bundle with a code. Throws `.wrongCode` on an authentication failure.
    public static func open(_ data: Data, code: String) throws -> SyncBundle {
        guard data.count > magic.count + 1 + saltLength,
              data.prefix(magic.count) == magic,
              data[magic.count] == version else { throw SyncError.badFormat }
        let saltStart = magic.count + 1
        let salt = data.subdata(in: saltStart ..< saltStart + saltLength)
        let ciphertext = data.subdata(in: saltStart + saltLength ..< data.count)
        let key = deriveKey(code: code, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(SyncBundle.self, from: plaintext)
        } catch is CryptoKitError {
            throw SyncError.wrongCode
        }
    }

    /// Derives the AES key from the normalized code + the file's salt (HKDF-SHA256).
    private static func deriveKey(code: String, salt: Data) -> SymmetricKey {
        let normalized = Data(normalize(code).utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: normalized),
            salt: salt,
            info: Data("searxly.sync.v1".utf8),
            outputByteCount: 32
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Pairing code

    /// Crockford-ish base32, no ambiguous characters (no 0/O/1/I/L/U).
    private static let codeAlphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A fresh 8-character pairing code, shown grouped as "XXXX-XXXX" (~40 bits).
    public static func generateCode() -> String {
        let chars = (0..<8).map { _ in codeAlphabet.randomElement()! }
        let s = String(chars)
        return "\(s.prefix(4))-\(s.suffix(4))"
    }

    /// Uppercase, strip separators/whitespace — so "k7f2-9qxm" and "K7F2 9QXM" match.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { codeAlphabet.contains($0) }
    }

    public static func isComplete(_ code: String) -> Bool {
        normalize(code).count == 8
    }
}

// MARK: - Merge

public enum SyncMerge {
    /// Union of two bookmark lists, de-duped by URL, keeping the earliest add date and newest title.
    public static func bookmarks(_ a: [SyncBookmark], _ b: [SyncBookmark]) -> [SyncBookmark] {
        var byURL: [String: SyncBookmark] = [:]
        for item in a + b {
            if let existing = byURL[item.url] {
                byURL[item.url] = SyncBookmark(
                    url: item.url,
                    title: item.title.isEmpty ? existing.title : item.title,
                    addedAt: min(existing.addedAt, item.addedAt)
                )
            } else {
                byURL[item.url] = item
            }
        }
        return byURL.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// Union of history, de-duped by URL, keeping the most recent visit.
    public static func history(_ a: [SyncHistoryItem], _ b: [SyncHistoryItem]) -> [SyncHistoryItem] {
        var byURL: [String: SyncHistoryItem] = [:]
        for item in a + b {
            if let existing = byURL[item.url], existing.visitedAt >= item.visitedAt { continue }
            byURL[item.url] = item
        }
        return byURL.values.sorted { $0.visitedAt > $1.visitedAt }
    }
}
