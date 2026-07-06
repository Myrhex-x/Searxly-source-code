//
//  SearxlyAIIdentity.swift
//  Searxly
//
//  The wallet-identity proof the app sends to the Searxly AI gateway so the gateway can authoritatively
//  resolve the user's tier (free / pass / holder) and enforce per-wallet daily limits server-side.
//
//  The app signs a short-lived SIWE-style session ONCE (one PIN unlock) — `dappPersonalSign` (EIP-191) —
//  caches it, and attaches it as headers on every cloud request. The gateway recovers the signer from the
//  signature, confirms it matches the claimed address, then checks on-chain $SEARXLY balance + the pass
//  payment. Nothing here is secret: it's a public address + a signature proving the user controls it.
//
//  `nonisolated` throughout so the (non-MainActor) networking layer can read the headers synchronously.
//

import Foundation

enum SearxlyAIIdentity {
    private nonisolated static let sessionKey = "SearxlyAI.session.v1"
    private nonisolated static let clientKey  = "SearxlyAI.clientId.v1"
    private nonisolated static let passTxKey  = "SearxlyAI.passTx.v1"

    /// How long a signed session stays valid before the app re-signs (re-prompting for the PIN).
    nonisolated static let sessionTTLDays = 7

    nonisolated struct Session: Codable, Equatable {
        var address: String
        var message: String
        var signature: String   // 65-byte EIP-191 personal_sign hex (0x…)
        var expiresAt: Date
    }

    // MARK: - Stored identity (device-local, non-secret)

    /// Stable per-install id used to meter FREE-tier users who haven't verified a wallet.
    nonisolated static var clientID: String {
        if let existing = UserDefaults.standard.string(forKey: clientKey) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clientKey)
        return id
    }

    nonisolated static var session: Session? {
        get {
            guard let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
            return try? JSONDecoder().decode(Session.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: sessionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sessionKey)
            }
        }
    }

    /// The USDC payment tx that bought the current pass (the gateway verifies it on-chain).
    nonisolated static var passTxHash: String? {
        get { UserDefaults.standard.string(forKey: passTxKey) }
        set {
            if let value = newValue { UserDefaults.standard.set(value, forKey: passTxKey) }
            else { UserDefaults.standard.removeObject(forKey: passTxKey) }
        }
    }

    nonisolated static var hasValidSession: Bool {
        if let s = session { return Date() < s.expiresAt }
        return false
    }

    nonisolated static var verifiedAddress: String? {
        guard let s = session, Date() < s.expiresAt else { return nil }
        return s.address
    }

    // MARK: - Headers attached to gateway requests

    /// Headers the gateway reads to identify the user and resolve their tier. Free-tier users send only
    /// the client id; verified users also send their address + signature; pass holders also send the tx.
    nonisolated static func headers() -> [String: String] {
        var h: [String: String] = [
            "X-Searxly-Client": clientID,
            // Device timezone offset (minutes). The gateway resets the daily count at the user's LOCAL
            // midnight — but from ITS OWN clock + this offset (locked server-side), so device-clock changes
            // can't be used to farm free resets.
            "X-Searxly-TZ-Offset": String(TimeZone.current.secondsFromGMT() / 60),
        ]
        if let s = session, Date() < s.expiresAt {
            h["X-Searxly-Address"] = s.address
            let msg64 = Data(s.message.utf8).base64EncodedString()
            h["X-Searxly-Auth"] = "\(msg64).\(s.signature)"
        }
        if let tx = passTxHash, !tx.isEmpty {
            h["X-Searxly-Pass"] = tx
        }
        return h
    }

    /// Builds the canonical session message the wallet signs. The gateway parses `Expires:` to reject
    /// stale sessions, and recovers the signer to confirm it equals `Address:`.
    nonisolated static func sessionMessage(address: String) -> (message: String, expiresAt: Date) {
        let now = Date()
        let expires = now.addingTimeInterval(Double(sessionTTLDays) * 86_400)
        let iso = ISO8601DateFormatter()
        let message = """
        Searxly AI — verify wallet for access.
        Address: \(address)
        Issued: \(iso.string(from: now))
        Expires: \(iso.string(from: expires))
        Nonce: \(UUID().uuidString)
        """
        return (message, expires)
    }

    nonisolated static func clearSession() {
        session = nil
        passTxHash = nil
    }
}
