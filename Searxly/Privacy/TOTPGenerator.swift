//
//  TOTPGenerator.swift
//  Searxly
//
//  Offline time-based one-time password (TOTP, RFC 6238) engine for the password vault.
//
//  Everything here is pure computation on a locally-stored shared secret — there is no network
//  call, no clock sync, and no server involved. A TOTP secret is a SECOND-FACTOR SEED: anyone
//  holding it can mint valid codes forever, so it is treated exactly like a password (Keychain
//  only, never in PasswordVault.json, excluded from plaintext CSV export by default).
//
//  Canonical storage format is the standard `otpauth://` URI. Storing the URI rather than a
//  decomposed struct means the algorithm/digits/period a site asked for survive round-tripping
//  verbatim, and import/export with other password managers is lossless.
//

import Foundation
import CryptoKit
import os

/// A parsed TOTP configuration. `secret` is the DECODED shared key, not the Base32 text.
nonisolated struct TOTPConfiguration: Equatable, Sendable {

    /// HMAC algorithm. SHA-1 is the near-universal default; RFC 6238 permits SHA-256/512 and a
    /// handful of sites (and Bitwarden exports) use them, so all three are supported.
    enum Algorithm: String, Sendable, CaseIterable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    var secret: Data
    var algorithm: Algorithm
    var digits: Int
    var period: Int
    var issuer: String?
    var account: String?

    init(
        secret: Data,
        algorithm: Algorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        issuer: String? = nil,
        account: String? = nil
    ) {
        self.secret = secret
        self.algorithm = algorithm
        // Clamp to the range real authenticators emit. An out-of-range value from a malformed URI
        // would otherwise produce codes no site accepts, which is far more confusing than silently
        // falling back to the RFC defaults.
        self.digits = (6...8).contains(digits) ? digits : 6
        self.period = (1...300).contains(period) ? period : 30
        self.issuer = issuer
        self.account = account
    }
}

nonisolated enum TOTPGenerator: Sendable {

    // MARK: - Code generation

    /// The current code for `configuration`, or nil if the secret is unusable.
    /// `date` is injectable so the RFC 6238 vectors can be tested against fixed timestamps.
    static func code(for configuration: TOTPConfiguration, at date: Date = Date()) -> String? {
        guard !configuration.secret.isEmpty else { return nil }
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(configuration.period))))
        return code(secret: configuration.secret,
                    counter: counter,
                    algorithm: configuration.algorithm,
                    digits: configuration.digits)
    }

    /// Seconds until the current code rolls over. Drives the countdown ring in the vault UI.
    static func secondsRemaining(for configuration: TOTPConfiguration, at date: Date = Date()) -> Int {
        let period = Double(configuration.period)
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return max(1, Int(period - elapsed.rounded(.down)))
    }

    /// Fraction of the current window already elapsed, 0...1. Used for the progress ring.
    static func progress(for configuration: TOTPConfiguration, at date: Date = Date()) -> Double {
        let period = Double(configuration.period)
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return min(1, max(0, elapsed / period))
    }

    /// RFC 4226 HOTP: HMAC the 8-byte big-endian counter, then dynamically truncate.
    private static func code(secret: Data, counter: UInt64, algorithm: TOTPConfiguration.Algorithm, digits: Int) -> String? {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)

        let digest: Data
        switch algorithm {
        case .sha1:   digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // Dynamic truncation (RFC 4226 §5.3): the low nibble of the last byte selects a 4-byte
        // window; masking the high bit avoids sign ambiguity across implementations.
        guard digest.count >= 20 else { return nil }
        let offset = Int(digest[digest.count - 1] & 0x0F)
        guard offset + 3 < digest.count else { return nil }

        let binary = (Int(digest[offset] & 0x7F) << 24)
            | (Int(digest[offset + 1]) << 16)
            | (Int(digest[offset + 2]) << 8)
            | Int(digest[offset + 3])

        // Integer powers only — pow() on Double loses exactness above 10^7 on some paths, and a
        // one-digit drift here silently produces codes that never validate.
        var modulus = 1
        for _ in 0..<digits { modulus *= 10 }

        return String(format: "%0\(digits)d", binary % modulus)
    }

    // MARK: - otpauth:// parsing

    /// Parses whatever the user pasted. Accepts a full `otpauth://totp/...` URI (what every QR
    /// code encodes) or a bare Base32 secret, which is what sites print next to the QR image and
    /// what users paste most often.
    static func parse(_ raw: String) -> TOTPConfiguration? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("otpauth://") {
            return parseURI(trimmed)
        }
        // Bare secret: adopt the RFC defaults every site assumes when it prints only the key.
        guard let secret = base32Decode(trimmed) else { return nil }
        return TOTPConfiguration(secret: secret)
    }

    private static func parseURI(_ uri: String) -> TOTPConfiguration? {
        guard let components = URLComponents(string: uri),
              components.host?.lowercased() == "totp" else {
            // `otpauth://hotp/` is counter-based, not time-based: it needs per-use counter
            // persistence and desync recovery, so refuse it rather than generate wrong codes.
            return nil
        }

        let items = components.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty
        }

        guard let secretText = query("secret"), let secret = base32Decode(secretText) else { return nil }

        // Label is `/Issuer:Account` or `/Account`, percent-decoded by URLComponents already.
        let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        var issuer = query("issuer")
        var account: String? = label.nilWhenEmpty

        if let separator = label.firstIndex(of: ":") {
            let labelIssuer = String(label[..<separator]).trimmingCharacters(in: .whitespaces)
            let labelAccount = String(label[label.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            // The `issuer` parameter wins when both are present — it is the authoritative one per
            // the Key URI spec, and the label prefix is frequently stale or abbreviated.
            if issuer == nil { issuer = labelIssuer.nilWhenEmpty }
            account = labelAccount.nilWhenEmpty
        }

        let algorithm = query("algorithm")
            .flatMap { TOTPConfiguration.Algorithm(rawValue: $0.uppercased()) } ?? .sha1

        return TOTPConfiguration(
            secret: secret,
            algorithm: algorithm,
            digits: query("digits").flatMap(Int.init) ?? 6,
            period: query("period").flatMap(Int.init) ?? 30,
            issuer: issuer,
            account: account
        )
    }

    /// Rebuilds the canonical `otpauth://` URI. This is what gets written to the Keychain, so it
    /// must round-trip `parse` exactly.
    static func uri(for configuration: TOTPConfiguration) -> String {
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"

        let account = configuration.account?.nilWhenEmpty
        let issuer = configuration.issuer?.nilWhenEmpty
        let label = [issuer, account].compactMap { $0 }.joined(separator: ":")
        components.path = "/" + (label.nilWhenEmpty ?? "Searxly")

        var items = [URLQueryItem(name: "secret", value: base32Encode(configuration.secret))]
        if let issuer { items.append(URLQueryItem(name: "issuer", value: issuer)) }
        items.append(URLQueryItem(name: "algorithm", value: configuration.algorithm.rawValue))
        items.append(URLQueryItem(name: "digits", value: String(configuration.digits)))
        items.append(URLQueryItem(name: "period", value: String(configuration.period)))
        components.queryItems = items

        return components.url?.absoluteString ?? ""
    }

    // MARK: - Base32 (RFC 4648)

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let decodeTable: [Character: Int] = {
        var table: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { table[character] = index }
        return table
    }()

    /// Decodes Base32, tolerating the formatting real sites use: lowercase, `=` padding, and the
    /// spaces or hyphens that secrets are usually printed with for readability.
    static func base32Decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { $0 != "=" && $0 != "-" && !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }

        var accumulator = 0
        var bits = 0
        var output = Data()

        for character in cleaned {
            guard let value = decodeTable[character] else { return nil }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                output.append(UInt8((accumulator >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }

        // Fewer than 8 bits of real payload means the input was a single stray character.
        return output.isEmpty ? nil : output
    }

    static func base32Encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var accumulator = 0
        var bits = 0
        var output = ""

        for byte in data {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(accumulator >> (bits - 5)) & 0x1F])
                bits -= 5
            }
        }
        if bits > 0 {
            output.append(alphabet[(accumulator << (5 - bits)) & 0x1F])
        }
        return output
    }
}

private extension String {
    /// nil for an empty string, so optional-chaining can drop absent URI fields.
    ///
    /// Explicitly `nonisolated`: the project builds with default main-actor isolation, which would
    /// otherwise infer @MainActor here and make it unreachable from this nonisolated enum.
    nonisolated var nilWhenEmpty: String? { isEmpty ? nil : self }
}
