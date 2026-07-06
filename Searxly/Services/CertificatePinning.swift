//
//  CertificatePinning.swift
//  Searxly
//
//  Optional public-key (SPKI) pinning for Searxly's OWN gateway (gateway.searxly.app).
//
//  HTTPS already stops a passive eavesdropper. Pinning additionally defends against an *active* MITM
//  holding a mis-issued / rogue-CA certificate for our host (the wallet's keyless 0x swaps and the
//  Searxly AI cloud both flow through the gateway, so that path is worth the extra belt).
//
//  Scope: pinning applies ONLY to `pinnedHosts`. Third-party hosts — the user's chosen RPC, Etherscan,
//  and every web page the browser loads — are NEVER pinned (we don't control their certs).
//
//  DISABLED BY DEFAULT: `pinnedPublicKeyHashes` is empty, so the delegate falls through to the system's
//  normal trust evaluation — behaviourally identical to `URLSession.shared`. To turn it on:
//    1. Compute the gateway's SubjectPublicKeyInfo SHA-256 (base64):
//         openssl s_client -connect gateway.searxly.app:443 -servername gateway.searxly.app </dev/null \
//           | openssl x509 -pubkey -noout \
//           | openssl pkey -pubin -outform der \
//           | openssl dgst -sha256 -binary | openssl enc -base64
//    2. Add that string — plus a BACKUP key's hash, so a planned cert/key rotation can't brick the app —
//       to `pinnedPublicKeyHashes`.
//    3. Test on device against the LIVE gateway before shipping. A wrong/stale pin blocks all gateway
//       calls (swaps + cloud AI), so this must be verified, never enabled blind.
//

import Foundation
import CryptoKit
import os

enum CertificatePinning {

    /// Hosts subject to pinning. Everything else passes through untouched.
    static let pinnedHosts: Set<String> = ["gateway.searxly.app"]

    /// Base64 SHA-256 of allowed SubjectPublicKeyInfo. EMPTY = pinning OFF (system default trust).
    /// Populate with the live key hash + a backup before enabling (see file header).
    static let pinnedPublicKeyHashes: Set<String> = []

    /// Shared session that pins `pinnedHosts`. Safe to use for any host — non-pinned hosts and an empty
    /// pin set both fall through to default handling. Gateway-bound callers should use this instead of
    /// `URLSession.shared`.
    static let session: URLSession = {
        URLSession(configuration: .default, delegate: PinningDelegate(), delegateQueue: nil)
    }()
}

final class PinningDelegate: NSObject, URLSessionDelegate {

    private static let log = Logger(subsystem: "com.myrhex.Searxly", category: "security")

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        // Only our own host, and only when at least one pin is configured.
        guard CertificatePinning.pinnedHosts.contains(host),
              !CertificatePinning.pinnedPublicKeyHashes.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Require a system-valid chain first (don't pin to something the OS already distrusts)…
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // …then require the leaf public key to match a pin.
        if let leafHash = Self.leafSPKISHA256Base64(trust),
           CertificatePinning.pinnedPublicKeyHashes.contains(leafHash) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            Self.log.error("Certificate pin mismatch for \(host, privacy: .public) — refusing the connection.")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// SHA-256 (base64) of the leaf certificate's SubjectPublicKeyInfo.
    private static func leafSPKISHA256Base64(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let header = asn1Header(for: key) else { return nil }

        var spki = Data(header)
        spki.append(keyData)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// ASN.1 SubjectPublicKeyInfo prefix for the common TLS key types (RSA-2048/4096, EC P-256), which
    /// cover effectively all real-world certificates. Returns nil for anything else (→ connection refused
    /// when pinning is on, which is the safe default).
    private static func asn1Header(for key: SecKey) -> [UInt8]? {
        guard let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              let bits = attrs[kSecAttrKeySizeInBits] as? Int else { return nil }

        if type == (kSecAttrKeyTypeRSA as String) {
            switch bits {
            case 2048: return Self.rsa2048Header
            case 4096: return Self.rsa4096Header
            default:   return nil
            }
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String), bits == 256 {
            return Self.ecP256Header
        }
        return nil
    }

    // Standard SPKI ASN.1 headers (well-known TrustKit constants).
    private static let rsa2048Header: [UInt8] = [0x30,0x82,0x01,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x01,0x0f,0x00]
    private static let rsa4096Header: [UInt8] = [0x30,0x82,0x02,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x02,0x0f,0x00]
    private static let ecP256Header: [UInt8]  = [0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00]
}
