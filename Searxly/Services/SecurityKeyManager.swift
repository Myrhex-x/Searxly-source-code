//
//  SecurityKeyManager.swift
//  Searxly
//
//  Optional hardware security-key (FIDO2 / YubiKey) support as a SECOND factor for App Lock, the
//  Password Vault, and the Wallet. Built on Apple's AuthenticationServices (the supported, sandbox-
//  friendly path) — works with any FIDO2 security key, fully offline (the app is its own relying party).
//
//  PHASE 1 = PRESENCE GATE. A successful unlock requires Touch ID / PIN *and* a tap on an enrolled key.
//  Security model: the OS only completes a FIDO assertion for our relying-party ID when a physical
//  enrolled authenticator is present, so "the OS returned a valid assertion for one of our enrolled
//  credential IDs" is a genuine second factor. (Full local signature verification + cryptographic
//  *binding* of the seed/vault to the key — so data literally can't be decrypted without it — is Phase 3.)
//
//  PREREQUISITE to actually use this at runtime (off by default until then):
//    1. Add the `com.apple.developer.associated-domains` entitlement: `webcredentials:www.searxly.app`.
//    2. Serve an AASA file at https://www.searxly.app/.well-known/apple-app-site-association (see
//       docs/SECURITY-KEYS.md). Without these the system rejects the key ceremony.
//    3. Build signed with the real team. Then enable in Settings → App Security.
//

import Foundation
import AuthenticationServices
import AppKit
import os

/// A single enrolled security key. We store only the FIDO credential ID + a friendly name — there is no
/// signing secret here (that lives on the key). Persisted in the Keychain.
struct SecurityKeyCredential: Codable, Identifiable, Equatable {
    let id: String            // base64 of the credential ID
    var name: String
    let dateAdded: Date

    var credentialID: Data { Data(base64Encoded: id) ?? Data() }
}

@MainActor
@Observable
final class SecurityKeyManager {
    static let shared = SecurityKeyManager()

    private static let log = Logger(subsystem: "com.myrhex.Searxly", category: "securitykey")

    /// Relying-party ID. MUST match the `webcredentials:` associated domain + the AASA file on the site.
    static let relyingPartyID = "www.searxly.app"

    // MARK: - Stored state

    /// Enrolled keys (loaded from the Keychain). Two or more are required before the feature can be armed.
    private(set) var credentials: [SecurityKeyCredential] = []

    // Feature flag + per-area requirements (small booleans → UserDefaults).
    private let featureKey = "SecurityKey.FeatureEnabled"
    private let requireAppLockKey = "SecurityKey.RequireForAppLock"
    private let requireVaultKey = "SecurityKey.RequireForVault"
    private let requireWalletKey = "SecurityKey.RequireForWallet"
    private let userHandleKey = "SecurityKey.LocalUserHandle"

    private static let keychainService = "com.myrhex.Searxly.securitykeys"
    private static let keychainAccount = "enrolled-credentials"

    private init() {
        loadCredentials()
    }

    // MARK: - Feature / requirement flags

    /// Master switch. Only meaningful with the entitlement + AASA in place and ≥1 enrolled key.
    var isFeatureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: featureKey) }
        set { UserDefaults.standard.set(newValue, forKey: featureKey) }
    }

    /// At least two keys must be enrolled before the second factor can be armed (anti-lockout).
    var meetsBackupRequirement: Bool { credentials.count >= 2 }

    var requireForAppLock: Bool {
        get { UserDefaults.standard.bool(forKey: requireAppLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: requireAppLockKey) }
    }
    var requireForVault: Bool {
        get { UserDefaults.standard.bool(forKey: requireVaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: requireVaultKey) }
    }
    var requireForWallet: Bool {
        get { UserDefaults.standard.bool(forKey: requireWalletKey) }
        set { UserDefaults.standard.set(newValue, forKey: requireWalletKey) }
    }

    /// Whether a key tap is currently required to unlock each area (armed only when the feature is on
    /// and at least one key is enrolled — so a stale flag can never lock the user out).
    var isRequiredForAppLock: Bool { isFeatureEnabled && !credentials.isEmpty && requireForAppLock }
    var isRequiredForVault: Bool   { isFeatureEnabled && !credentials.isEmpty && requireForVault }
    var isRequiredForWallet: Bool  { isFeatureEnabled && !credentials.isEmpty && requireForWallet }

    // MARK: - Enrollment

    enum EnrollResult {
        case success(SecurityKeyCredential)
        case failure(String)
    }

    /// Registers a new security key (the system shows the "insert and tap your key" UI).
    func enroll(name: String) async -> EnrollResult {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(
            challenge: Self.randomChallenge(),
            displayName: "Searxly",
            name: name.isEmpty ? "Searxly Security Key" : name,
            userID: localUserHandle()
        )
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
        request.userVerificationPreference = .preferred
        request.attestationPreference = .none
        // Stop the same physical key being enrolled twice.
        request.excludedCredentials = credentials.map {
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.credentialID, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        }

        do {
            let ceremony = SecurityKeyCeremony()
            let auth = try await ceremony.perform([request])
            guard let reg = auth.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration else {
                return .failure("The key returned an unexpected response. Please try again.")
            }
            let cred = SecurityKeyCredential(
                id: reg.credentialID.base64EncodedString(),
                name: name.isEmpty ? "Security Key \(credentials.count + 1)" : name,
                dateAdded: Date()
            )
            credentials.append(cred)
            persistCredentials()
            Self.log.notice("Enrolled a new security key (total: \(self.credentials.count, privacy: .public)).")
            return .success(cred)
        } catch {
            return .failure(Self.friendlyError(error))
        }
    }

    /// Removes an enrolled key. If this drops below the backup requirement, the second factor is disarmed
    /// for safety (so the user can never be left with a single point of failure they think is a backup).
    func removeCredential(_ credential: SecurityKeyCredential) {
        credentials.removeAll { $0.id == credential.id }
        persistCredentials()
        if !meetsBackupRequirement {
            requireForAppLock = false
            requireForVault = false
            requireForWallet = false
            if credentials.isEmpty { isFeatureEnabled = false }
        }
    }

    // MARK: - Assertion (the second-factor check)

    /// Runs an assertion ceremony against the enrolled keys. Returns true only when the OS completes a
    /// FIDO assertion for our relying-party with one of our enrolled credential IDs.
    func assert() async -> Bool {
        guard !credentials.isEmpty else { return false }
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: Self.randomChallenge())
        request.allowedCredentials = credentials.map {
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.credentialID, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        }
        request.userVerificationPreference = .preferred

        do {
            let ceremony = SecurityKeyCeremony()
            let auth = try await ceremony.perform([request])
            guard let assertion = auth.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion else {
                return false
            }
            let usedID = assertion.credentialID.base64EncodedString()
            let ok = credentials.contains { $0.id == usedID }
            if !ok { Self.log.error("Assertion used a credential ID we did not enroll — rejecting.") }
            return ok
        } catch {
            Self.log.info("Security-key assertion did not complete: \(Self.friendlyError(error), privacy: .public)")
            return false
        }
    }

    /// Second-factor gate for App Lock: passes through when not required, otherwise demands a key tap.
    func assertIfRequiredForAppLock() async -> Bool { isRequiredForAppLock ? await assert() : true }
    /// Second-factor gate for the Password Vault.
    func assertIfRequiredForVault() async -> Bool { isRequiredForVault ? await assert() : true }
    /// Second-factor gate for the Wallet (gate only — Ledger remains the transaction signer).
    func assertIfRequiredForWallet() async -> Bool { isRequiredForWallet ? await assert() : true }

    // MARK: - Persistence (Keychain)

    private func persistCredentials() {
        let data = (try? JSONEncoder().encode(credentials)) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Self.log.error("Failed to persist security-key credentials (status \(status, privacy: .public)).")
        }
    }

    private func loadCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let decoded = try? JSONDecoder().decode([SecurityKeyCredential].self, from: data) {
            credentials = decoded
        }
    }

    // MARK: - Helpers

    private static func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Stable per-install WebAuthn user handle (not secret — it's the credential's user id).
    private func localUserHandle() -> Data {
        if let existing = UserDefaults.standard.data(forKey: userHandleKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let handle = Data(bytes)
        UserDefaults.standard.set(handle, forKey: userHandleKey)
        return handle
    }

    private static func friendlyError(_ error: Error) -> String {
        if let asError = error as? ASAuthorizationError {
            switch asError.code {
            case .canceled:        return "Cancelled."
            case .failed:          return "The key request failed. Make sure your key is inserted and try again."
            case .invalidResponse: return "The key returned an invalid response."
            case .notHandled:      return "The request wasn't handled. Check that webcredentials:www.searxly.app is set up."
            case .notInteractive:  return "The system couldn't show the key prompt."
            // Plain `default` (not `@unknown default`): newer SDKs add known cases
            // (matchedExcludedCredential, credentialImport/Export, preferSignInWithApple,
            // deviceNotConfiguredForPasskeyCreation, …) that all want the same generic fallback.
            // A catch-all keeps the switch exhaustive without per-OS availability guards.
            default:               return asError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - ASAuthorizationController driver (one-shot async wrapper)

/// Bridges a single `ASAuthorizationController` request to async/await. Held strongly by the caller for
/// the duration of the ceremony (the controller keeps only a weak delegate reference).
private final class SecurityKeyCeremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
