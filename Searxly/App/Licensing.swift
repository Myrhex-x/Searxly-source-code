//
//  Licensing.swift
//  Searxly
//
//  Scaffolding for a future PAID Searxly Maximum — deliberately inert today. While
//  `Licensing.paymentsEnabled == false`, Maximum is FREE: every gated feature returns unlocked and no
//  purchase UI appears. The day payments go live you (1) generate a signing keypair, (2) paste the
//  PUBLIC half into `verifyingPublicKeyBase64`, (3) flip `paymentsEnabled` to true. Nothing else changes.
//
//  Why this shape:
//    • OFFLINE verification. A Maximum license is a short signed token verified ON DEVICE against a
//      bundled Ed25519 public key — no accounts, no phone-home, no license server call at runtime. That
//      is the only model consistent with Maximum's "100% local, engineered not to leak" promise.
//    • CHANNEL-AGNOSTIC. The app verifies the signature and ignores HOW the license was bought. A later
//      backend can mint tokens for credit cards (e.g. Stripe), on-chain crypto, Apple IAP, or comps with
//      ZERO client change — the channel is just a provenance field on the payload.
//    • The PRIVATE signing key lives only on your minter/server and never ships in the app, so a user
//      cannot forge a license, exactly like Sparkle's update-signing key.
//
//  Token format (what your minter emits):  base64url(payloadJSON) + "." + base64url(ed25519_signature)
//  where the signature is over the RAW payloadJSON bytes (we verify the transmitted bytes, so there is
//  no JSON-canonicalisation footgun). See `MaximumLicense` for the payload fields.
//

import Foundation
import CryptoKit

/// How a Maximum license was obtained. Provenance only — the app treats every validly-signed token the
/// same, so new purchase rails can be added server-side without touching the client.
enum LicenseChannel: String, Codable, Sendable {
    case card       // credit / debit (e.g. Stripe) — the "one day I'll allow credit card" path
    case crypto     // on-chain payment (USDC / $SEARXLY)
    case appleIAP   // App Store in-app purchase, if ever distributed there
    case comp       // complimentary / press / team
    case unknown
}

/// The signed, offline-verifiable Maximum license payload.
struct MaximumLicense: Codable, Sendable, Equatable {
    /// Opaque unique id for this license (for support / revocation lists later).
    var licenseID: String
    /// Product this unlocks. Guarded so a token minted for something else can't unlock Maximum.
    var product: String
    var channel: LicenseChannel
    var issuedAt: Date
    /// nil = perpetual. Set for subscriptions / time-boxed passes.
    var expiresAt: Date?
    /// Optional NON-PII reference to the buyer (a salted hash of email or wallet). Never store cleartext
    /// PII in a license that lives on the user's disk.
    var holderRef: String?

    static let maximumProduct = "searxly.maximum"
    var isForMaximum: Bool { product == Self.maximumProduct }
    var isExpired: Bool { if let e = expiresAt { return Date() > e }; return false }
    var isValidNow: Bool { isForMaximum && !isExpired }
}

/// Global licensing configuration. The two constants below are the ONLY things you touch to go live.
enum Licensing {
    /// MASTER SWITCH. `false` → Maximum is free, everything unlocked, no purchase UI. Flip to `true`
    /// only after `verifyingPublicKeyBase64` is set, or the app would gate features with no way to unlock.
    static let paymentsEnabled = false

    /// Base64 (standard) of the 32-byte Ed25519 PUBLIC key that license tokens are verified against.
    /// The matching PRIVATE key lives ONLY on your minter and never ships here. Generate with CryptoKit:
    ///   `Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()`
    /// BLANK until you create the keypair.
    static let verifyingPublicKeyBase64 = ""

    static var verifyingPublicKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: verifyingPublicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else { return nil }
        return key
    }
}

/// Capabilities that will one day require a paid Maximum license. Every call site gates through
/// `LicenseManager.isUnlocked(_:)` NOW, so enabling payments later is a config flip, not a code hunt.
enum PremiumFeature: String, CaseIterable, Sendable {
    /// Using the faster Searxly VPN lane instead of (slower, most-private) Tor. Tor is always free.
    case fasterVPN
}

@MainActor
@Observable
final class LicenseManager {
    static let shared = LicenseManager()

    enum State: Equatable {
        case free                       // payments off, or no license — everything unlocked while free
        case licensed(MaximumLicense)
        case expired
        case invalid
    }

    private(set) var state: State = .free
    private static let tokenKey = "Searxly.Maximum.LicenseToken"

    private init() { reload() }

    var license: MaximumLicense? { if case .licensed(let l) = state { return l }; return nil }
    var isLicensed: Bool { if case .licensed = state { return true }; return false }

    /// THE entitlement gate. While `paymentsEnabled` is false this always returns `true` (free preview),
    /// so today Maximum ships every feature unlocked; later it reflects a real, unexpired license.
    func isUnlocked(_ feature: PremiumFeature) -> Bool {
        guard Licensing.paymentsEnabled else { return true }
        if case .licensed(let l) = state, l.isValidNow { return true }
        return false
    }

    /// Activate a license token the user pasted / that arrived via a `searxly://license/<token>` deep link.
    @discardableResult
    func activate(token rawToken: String) -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Licensing.verifyingPublicKey,
              let lic = Self.decodeAndVerify(token, publicKey: key), lic.isForMaximum else {
            state = .invalid
            return false
        }
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        state = lic.isExpired ? .expired : .licensed(lic)
        return !lic.isExpired
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        state = .free
    }

    private func reload() {
        guard Licensing.paymentsEnabled,
              let token = UserDefaults.standard.string(forKey: Self.tokenKey),
              let key = Licensing.verifyingPublicKey,
              let lic = Self.decodeAndVerify(token, publicKey: key), lic.isForMaximum else {
            state = .free
            return
        }
        state = lic.isExpired ? .expired : .licensed(lic)
    }

    /// Verify a `payload.signature` token against `publicKey` and decode the payload. Verifies over the
    /// transmitted payload bytes, so there is no re-serialisation / canonicalisation mismatch.
    static func decodeAndVerify(_ token: String, publicKey: Curve25519.Signing.PublicKey) -> MaximumLicense? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = Data(base64URLEncoded: String(parts[0])),
              let signature = Data(base64URLEncoded: String(parts[1])),
              publicKey.isValidSignature(signature, for: payload) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MaximumLicense.self, from: payload)
    }
}

extension Data {
    /// Decode base64url (RFC 4648 §5, no padding) as used in the license token.
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
