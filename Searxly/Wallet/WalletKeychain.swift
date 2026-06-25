//
//  WalletKeychain.swift
//  Searxly
//
//  Stores the encrypted seed phrase in the macOS Keychain.
//
//  Security model:
//   - Seed is AES-GCM encrypted with a key derived from the user's PIN via PBKDF2-SHA256
//     (200k iterations) using a per-wallet RANDOM salt (prevents precomputed/rainbow attacks
//     across wallets).
//   - A second copy of the seed is encrypted with a key derived from the high-entropy recovery
//     code, so "forgot PIN" can genuinely re-key the seed to a new PIN.
//   - All items are device-only (kSecAttrAccessibleWhenUnlockedThisDeviceOnly), never iCloud-synced.
//

import Foundation
import os
import Security
import CryptoKit
import CommonCrypto
import LocalAuthentication

// `nonisolated`: the module defaults to MainActor isolation, but every operation here uses only
// thread-safe Security / CryptoKit / Foundation APIs and is called from both MainActor (WalletManager)
// and nonisolated (WalletConfig, networking) contexts. Opting the whole type out keeps it callable
// from anywhere without actor hops.
nonisolated enum WalletKeychain {

    private static let service = "com.myrhex.Searxly.wallet"
    private static let seedAccount = "wallet-seed"
    private static let seedBoundAccount = "wallet-seed-se"            // Secure-Enclave-bound seed copy
    private static let recoverySeedAccount = "wallet-recovery-seed"
    private static let saltAccount = "wallet-kdf-salt"
    private static let biometricPINAccount = "wallet-biometric-pin"
    private static let connectedSitesAccount = "wallet-connected-sites"
    private static let addressAccount = "wallet-address"
    private static let zeroExKeyAccount = "wallet-0x-api-key"
    private static let basescanKeyAccount = "wallet-basescan-api-key"
    private static let activityAccount = "wallet-activity"
    private static let accountsAccount = "wallet-accounts"
    private static let siteAccountsAccount = "wallet-site-accounts"
    private static let rotationAccountsAccount = "wallet-rotation-accounts"
    private static let importedKeysAccount = "wallet-imported-keys"
    private static let importedKeysBoundAccount = "wallet-imported-keys-se"   // SE-bound imported-keys copy
    private static let seBindingKeyTag = "com.myrhex.Searxly.wallet.se-binding".data(using: .utf8)!
    private static let contactsAccount = "wallet-contacts"
    private static let portfolioHistoryAccount = "wallet-portfolio-history"

    private static let pbkdf2Rounds: UInt32 = 200_000

    // MARK: - Seed (PIN-encrypted)

    @discardableResult
    static func saveSeed(_ words: [String], pin: String) -> Bool {
        guard let phraseData = words.joined(separator: " ").data(using: .utf8) else { return false }
        let key = deriveKey(from: pin, salt: loadOrCreateSalt())
        guard let encrypted = try? encryptAES(phraseData, key: key) else { return false }
        // Wrap the PIN-encrypted blob to the Secure Enclave so the 6-digit PIN can't be brute-forced
        // OFFLINE from an extracted keychain copy. Falls back to an unbound store if SE is unavailable.
        return storeCiphertextBound(encrypted, unbound: seedAccount, bound: seedBoundAccount)
    }

    static func loadSeed(pin: String) -> [String]? {
        // Diagnostic: distinguish "no readable ciphertext" (storage/Secure-Enclave failure) from
        // "ciphertext present but decrypt failed" (wrong PIN OR salt/key mismatch). Without this, both
        // surface to the UI as the same "incorrect PIN", which masks a keychain read failure.
        guard let encrypted = loadCiphertext(unbound: seedAccount, bound: seedBoundAccount) else {
            Log.security.error("WalletKeychain.loadSeed: no readable seed ciphertext (storage/SE failure, NOT a wrong PIN)")
            return nil
        }
        if let salt = loadSalt() {
            let words = decryptSeed(encrypted, secret: pin, salt: salt)
            if words == nil { Log.security.error("WalletKeychain.loadSeed: ciphertext present but AES-GCM decrypt failed (wrong PIN or key/salt mismatch)") }
            return words
        }
        // Legacy wallet (created before per-wallet salts): decrypt with the old fixed-salt/100k KDF,
        // then transparently migrate it to the new random-salt/200k KDF so it's upgraded going forward.
        if let words = legacyDecryptSeed(encrypted, pin: pin) {
            saveSeed(words, pin: pin)
            return words
        }
        Log.security.error("WalletKeychain.loadSeed: no per-wallet salt and legacy decrypt failed")
        return nil
    }

    private static func legacyDecryptSeed(_ encrypted: Data, pin: String) -> [String]? {
        let salt = Data("searxly-wallet-v1".utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000, &derived, 32)
        }
        guard let decrypted = try? decryptAES(encrypted, key: Data(derived)),
              let phrase = String(data: decrypted, encoding: .utf8) else { return nil }
        let words = phrase.components(separatedBy: " ").filter { !$0.isEmpty }
        return words.isEmpty ? nil : words
    }

    /// Whether the seed CIPHERTEXT can be retrieved at all, independent of the PIN. `false` here means
    /// a storage / Secure-Enclave read failure — NOT a wrong PIN — so the UI can say so honestly
    /// instead of blaming the user's PIN. (Used to tell the two failure modes apart at unlock.)
    static func seedCiphertextReadable() -> Bool {
        loadCiphertext(unbound: seedAccount, bound: seedBoundAccount) != nil
    }

    /// Whether any seed item exists in the Keychain at all (bound or unbound), regardless of whether
    /// it can currently be read back.
    static func seedItemPresent() -> Bool {
        loadItem(account: seedBoundAccount) != nil || loadItem(account: seedAccount) != nil
    }

    static func deleteSeed() {
        // Wipe every wallet keychain item so nothing lingers after a delete.
        [seedAccount, seedBoundAccount, recoverySeedAccount, saltAccount, biometricPINAccount,
         connectedSitesAccount, addressAccount, activityAccount,
         accountsAccount, siteAccountsAccount, rotationAccountsAccount, importedKeysAccount,
         importedKeysBoundAccount, contactsAccount, portfolioHistoryAccount,
         zeroExKeyAccount, basescanKeyAccount].forEach(deleteItem)
        deleteSecureEnclaveKey()   // drop the device-binding key so nothing lingers after a delete
    }

    // MARK: - Address book (saved recipient contacts — who you pay is private)

    static func saveContacts(_ contacts: [WalletContact]) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        _ = saveItem(data, account: contactsAccount)
    }

    static func loadContacts() -> [WalletContact] {
        guard let data = loadItem(account: contactsAccount),
              let contacts = try? JSONDecoder().decode([WalletContact].self, from: data) else { return [] }
        return contacts
    }

    // MARK: - HD accounts (index + address + label; addresses are public but kept device-only)

    static func saveAccounts(_ accounts: [WalletAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        _ = saveItem(data, account: accountsAccount)
    }

    static func loadAccounts() -> [WalletAccount] {
        guard let data = loadItem(account: accountsAccount),
              let accounts = try? JSONDecoder().decode([WalletAccount].self, from: data) else { return [] }
        return accounts
    }

    /// Per-dApp rotation accounts — a pool of hidden HD accounts (high index range) each assigned to
    /// one site so connected dApps can't be cross-linked to a single on-chain identity.
    static func saveRotationAccounts(_ accounts: [WalletAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        _ = saveItem(data, account: rotationAccountsAccount)
    }

    static func loadRotationAccounts() -> [WalletAccount] {
        guard let data = loadItem(account: rotationAccountsAccount),
              let accounts = try? JSONDecoder().decode([WalletAccount].self, from: data) else { return [] }
        return accounts
    }

    // MARK: - Imported private keys (one per imported account, encrypted under the PIN like the seed)

    /// Stores the full map of imported account index → raw 32-byte private key, encrypted with the
    /// PIN-derived key (same AES-GCM + per-wallet salt as the seed). Re-encrypts the whole blob.
    @discardableResult
    static func saveImportedKeys(_ keysByIndex: [Int: Data], pin: String) -> Bool {
        let map = keysByIndex.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value.map { String(format: "%02x", $0) }.joined() }
        guard let json = try? JSONSerialization.data(withJSONObject: map) else { return false }
        let key = deriveKey(from: pin, salt: loadOrCreateSalt())
        guard let encrypted = try? encryptAES(json, key: key) else { return false }
        return storeCiphertextBound(encrypted, unbound: importedKeysAccount, bound: importedKeysBoundAccount)
    }

    static func loadImportedKeys(pin: String) -> [Int: Data] {
        guard let encrypted = loadCiphertext(unbound: importedKeysAccount, bound: importedKeysBoundAccount), let salt = loadSalt(),
              let decrypted = try? decryptAES(encrypted, key: deriveKey(from: pin, salt: salt)),
              let map = try? JSONSerialization.jsonObject(with: decrypted) as? [String: String] else { return [:] }
        var result = [Int: Data]()
        for (k, v) in map {
            guard let idx = Int(k) else { continue }
            var bytes = [UInt8](); var i = v.startIndex
            while i < v.endIndex {
                let n = v.index(i, offsetBy: 2)
                if let b = UInt8(v[i..<n], radix: 16) { bytes.append(b) }
                i = n
            }
            result[idx] = Data(bytes)
        }
        return result
    }

    // MARK: - Per-site account map (which account each connected origin sees → privacy isolation)

    static func saveSiteAccounts(_ map: [String: Int]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        _ = saveItem(data, account: siteAccountsAccount)
    }

    static func loadSiteAccounts() -> [String: Int] {
        guard let data = loadItem(account: siteAccountsAccount),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }

    // MARK: - API keys (user-entered service secrets — out of plaintext UserDefaults/backups)

    static func saveZeroExKey(_ key: String) { saveString(key, account: zeroExKeyAccount) }
    static func loadZeroExKey() -> String? { loadString(account: zeroExKeyAccount) }
    static func saveBasescanKey(_ key: String) { saveString(key, account: basescanKeyAccount) }
    static func loadBasescanKey() -> String? { loadString(account: basescanKeyAccount) }

    // MARK: - Local activity feed (encrypted at rest in the Keychain, not plaintext UserDefaults)

    static func saveActivity(_ data: Data) { _ = saveItem(data, account: activityAccount) }
    static func loadActivity() -> Data? { loadItem(account: activityAccount) }
    static func deleteActivity() { deleteItem(activityAccount) }

    // MARK: - Portfolio value history (per-account snapshots — wealth/behavior data, device-only)

    static func savePortfolioHistory(_ data: Data) { _ = saveItem(data, account: portfolioHistoryAccount) }
    static func loadPortfolioHistory() -> Data? { loadItem(account: portfolioHistoryAccount) }
    static func deletePortfolioHistory() { deleteItem(portfolioHistoryAccount) }

    private static func saveString(_ value: String, account: String) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { deleteItem(account); return }
        _ = saveItem(data, account: account)
    }

    private static func loadString(account: String) -> String? {
        guard let data = loadItem(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Generic string secrets keyed by an arbitrary account (used by WalletConnect for the project
    // id and relay client key). Device-only, out of backups, like everything else here.
    static func saveString(_ value: String, forKey key: String) { saveString(value, account: key) }
    static func loadString(forKey key: String) -> String? { loadString(account: key) }

    // MARK: - Public address (kept in the Keychain so the device↔on-chain-identity link stays
    // out of plaintext UserDefaults and backups; the address itself is public on-chain)

    static func saveAddress(_ address: String) {
        guard let data = address.data(using: .utf8) else { return }
        _ = saveItem(data, account: addressAccount)
    }

    static func loadAddress() -> String? {
        guard let data = loadItem(account: addressAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Connected dApp sites (which sites you use is browsing-habit data → keep it
    // encrypted + device-only + out of backups, not in plaintext UserDefaults)

    static func saveConnectedSites(_ origins: [String]) {
        guard let data = try? JSONEncoder().encode(origins) else { return }
        _ = saveItem(data, account: connectedSitesAccount)
    }

    static func loadConnectedSites() -> [String] {
        guard let data = loadItem(account: connectedSitesAccount),
              let origins = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return origins
    }

    // MARK: - Recovery copy (recovery-code-encrypted)

    /// Stores a second copy of the seed, encrypted with the recovery code. Enables a real
    /// "forgot PIN" reset: decrypt with the code, re-encrypt under a new PIN.
    @discardableResult
    static func saveRecoverySeed(_ words: [String], recoveryCode: String) -> Bool {
        guard let phraseData = words.joined(separator: " ").data(using: .utf8) else { return false }
        let key = deriveKey(from: recoveryCode.uppercased(), salt: loadOrCreateSalt())
        guard let encrypted = try? encryptAES(phraseData, key: key) else { return false }
        return saveItem(encrypted, account: recoverySeedAccount)
    }

    static func loadRecoverySeed(recoveryCode: String) -> [String]? {
        guard let encrypted = loadItem(account: recoverySeedAccount), let salt = loadSalt() else { return nil }
        return decryptSeed(encrypted, secret: recoveryCode.uppercased(), salt: salt)
    }

    // MARK: - Biometric unlock secret

    /// Stores the PIN behind a Secure-Enclave-backed biometric gate (`.biometryCurrentSet`): the
    /// item can ONLY be read after a fresh biometric match, and is invalidated if the device's
    /// biometric enrollment changes. This way, local code (or forensic extraction) can't read the
    /// PIN — and thus can't shortcut the seed — without the user's live Face/Touch ID.
    @discardableResult
    static func saveBiometricPIN(_ pin: String) -> Bool {
        guard let data = pin.data(using: .utf8) else { return false }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil) else { return false }
        deleteItem(biometricPINAccount)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: biometricPINAccount,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the biometric PIN. Pass the LAContext from a just-completed biometric evaluation so the
    /// Keychain reuses that authentication instead of prompting a second time.
    static func loadBiometricPIN(context: LAContext? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: biometricPINAccount,
            kSecReturnData as String: true,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        else {
            // kSecUseOperationPrompt is deprecated; supply the prompt via an LAContext instead.
            let ctx = LAContext()
            ctx.localizedReason = "Unlock your Searxly wallet"
            query[kSecUseAuthenticationContext as String] = ctx
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteBiometricPIN() {
        deleteItem(biometricPINAccount)
    }

    // MARK: - Crypto

    private static func decryptSeed(_ encrypted: Data, secret: String, salt: Data) -> [String]? {
        let key = deriveKey(from: secret, salt: salt)
        guard let decrypted = try? decryptAES(encrypted, key: key),
              let phrase = String(data: decrypted, encoding: .utf8) else { return nil }
        let words = phrase.components(separatedBy: " ").filter { !$0.isEmpty }
        return words.isEmpty ? nil : words
    }

    private static func deriveKey(from secret: String, salt: Data) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                secret, secret.utf8.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                pbkdf2Rounds,
                &derived, 32
            )
        }
        return Data(derived)
    }

    /// Per-wallet random KDF salt. Created once and stored device-only.
    private static func loadOrCreateSalt() -> Data {
        if let existing = loadSalt() { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        let salt = Data(bytes)
        _ = saveItem(salt, account: saltAccount)
        return salt
    }

    private static func loadSalt() -> Data? { loadItem(account: saltAccount) }

    private static func encryptAES(_ plaintext: Data, key: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined!
    }

    private static func decryptAES(_ ciphertext: Data, key: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: key))
    }

    // MARK: - Secure Enclave device binding
    //
    // The PIN-encrypted seed (and imported keys) are additionally wrapped to a NON-EXTRACTABLE Secure
    // Enclave key. This defeats the realistic attack on a short PIN: an attacker who extracts the
    // keychain blob can't brute-force the 6-digit PIN OFFLINE, because the wrapped blob can only be
    // unwrapped on THIS device's Secure Enclave. (It does not stop live malware already running on the
    // unlocked device — that's what the optional passphrase is for.)
    //
    // Deliberately layered & safe:
    //  • The recovery-code copy is NEVER bound, so a recovery code still restores the wallet on a NEW
    //    device. The recovery code is high-entropy, so it isn't brute-forceable anyway.
    //  • Everything is best-effort: if the Enclave is unavailable or any op fails, we store/read the
    //    UNBOUND blob exactly as before — a wallet is never lost to SE issues.
    //  • Before deleting the unbound (brute-forceable) copy, we round-trip the bound copy, so we never
    //    commit a blob we can't read back.

    /// Whether this device can create Secure-Enclave-backed keys (Apple Silicon / T2 Macs). When this
    /// is false, the seed can only be wrapped under the PIN-derived key with NO device binding, so a
    /// short PIN becomes the sole barrier and is brute-forceable offline from an extracted blob — setup
    /// should then require a high-entropy passphrase instead of a 6-digit PIN. Probed once with an
    /// ephemeral (non-persistent) key so it has no side effects.
    static let isSecureEnclaveAvailable: Bool = {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil) else { return false }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,   // ephemeral — pure capability probe, never stored
                kSecAttrAccessControl as String: access,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attrs as CFDictionary, &error) != nil
    }()

    /// Loads (or creates once) the device's Secure-Enclave binding key. nil when SE is unavailable
    /// (older hardware / unusual signing) — callers then fall back to unbound storage.
    private static func secureEnclaveKey() -> SecKey? {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: seBindingKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var existing: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &existing) == errSecSuccess, let key = existing {
            return (key as! SecKey)
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: seBindingKeyTag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attrs as CFDictionary, &error)
    }

    private static func deleteSecureEnclaveKey() {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: seBindingKeyTag,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }

    private static let seAlgorithm: SecKeyAlgorithm = .eciesEncryptionCofactorX963SHA256AESGCM

    /// Wraps data to the Enclave key's public key (ECIES). nil if SE unavailable/unsupported.
    private static func seWrap(_ data: Data) -> Data? {
        guard let priv = secureEnclaveKey(), let pub = SecKeyCopyPublicKey(priv),
              SecKeyIsAlgorithmSupported(pub, .encrypt, seAlgorithm) else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCreateEncryptedData(pub, seAlgorithm, data as CFData, &error) as Data?
    }

    /// Unwraps data with the Enclave private key. nil if SE unavailable or the blob wasn't wrapped here.
    private static func seUnwrap(_ data: Data) -> Data? {
        guard let priv = secureEnclaveKey(),
              SecKeyIsAlgorithmSupported(priv, .decrypt, seAlgorithm) else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCreateDecryptedData(priv, seAlgorithm, data as CFData, &error) as Data?
    }

    /// Stores a PIN-encrypted blob, preferring the Enclave-bound form. Only deletes the unbound copy
    /// after the bound copy round-trips, so we can never lock the user out via a write we can't read.
    @discardableResult
    private static func storeCiphertextBound(_ ciphertext: Data, unbound: String, bound: String) -> Bool {
        if let wrapped = seWrap(ciphertext), let check = seUnwrap(wrapped), check == ciphertext,
           saveItem(wrapped, account: bound) {
            deleteItem(unbound)
            Log.security.debug("WalletKeychain: Secure Enclave binding active for \(bound, privacy: .public)")
            return true
        }
        // SE unavailable / failed → behave exactly as before (unbound). Clear any stale bound copy.
        deleteItem(bound)
        Log.security.debug("WalletKeychain: Secure Enclave binding unavailable — storing \(unbound, privacy: .public) unbound")
        return saveItem(ciphertext, account: unbound)
    }

    /// Reads a PIN-encrypted blob, preferring the Enclave-bound copy and transparently migrating any
    /// legacy unbound copy into the bound form (no PIN needed — it wraps the already-encrypted blob).
    private static func loadCiphertext(unbound: String, bound: String) -> Data? {
        if let boundBlob = loadItem(account: bound) {
            if let ct = seUnwrap(boundBlob) { return ct }
            // Bound copy present but the Enclave couldn't unwrap it (SE key inaccessible — common when
            // the wallet was created by a different code-signing identity / earlier build). Use any
            // remaining unbound copy; otherwise this PIN copy is unreadable → restore via recovery code.
            Log.security.error("WalletKeychain: SE-bound \(bound, privacy: .public) present but unwrap FAILED; trying unbound fallback")
            let fallback = loadItem(account: unbound)
            if fallback == nil {
                Log.security.error("WalletKeychain: no unbound fallback for \(bound, privacy: .public) — seed unreadable with PIN (use recovery code)")
            }
            return fallback
        }
        if let unboundBlob = loadItem(account: unbound) {
            storeCiphertextBound(unboundBlob, unbound: unbound, bound: bound)   // upgrade in place
            return unboundBlob
        }
        Log.security.error("WalletKeychain: no seed ciphertext at all (bound=\(bound, privacy: .public), unbound=\(unbound, privacy: .public))")
        return nil
    }

    // MARK: - Keychain primitives
    //
    // We use the **data-protection keychain** (kSecUseDataProtectionKeychain) rather than the legacy
    // file-based keychain. The legacy keychain gates access by a per-item ACL tied to the app's code
    // SIGNATURE, so development/ad-hoc builds (whose signature changes every rebuild) trigger a macOS
    // "Searxly wants to use your confidential information…" prompt for EACH item, every launch —
    // i.e. the popup spam. The data-protection keychain instead scopes items to the sandboxed app's
    // own access group, so there is no per-signature ACL prompt at all.
    //
    // We probe availability once (some signing setups lack the entitlement); if unavailable we fall
    // back to the legacy keychain so behavior never regresses. Existing legacy items are migrated to
    // the data-protection keychain transparently on first read (a one-time prompt at most, then never
    // again).

    /// Whether the data-protection keychain is usable for this signed build (probed once).
    private static let useDataProtection: Bool = probeDataProtectionKeychain()

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    @discardableResult
    private static func saveItem(_ data: Data, account: String) -> Bool {
        deleteItem(account)
        var query = baseQuery(account: account, dataProtection: useDataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func loadItem(account: String) -> Data? {
        if useDataProtection {
            if let data = rawLoad(account: account, dataProtection: true) { return data }
            // Not in the data-protection keychain yet — migrate any legacy copy (one-time).
            if let legacy = rawLoad(account: account, dataProtection: false) {
                migrateToDataProtection(legacy, account: account)
                return legacy
            }
            return nil
        }
        return rawLoad(account: account, dataProtection: false)
    }

    private static func rawLoad(account: String, dataProtection: Bool) -> Data? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Copies a legacy item into the data-protection keychain, then removes the legacy copy so it
    /// never triggers a signature-ACL prompt again.
    private static func migrateToDataProtection(_ data: Data, account: String) {
        var add = baseQuery(account: account, dataProtection: true)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
        }
    }

    private static func deleteItem(_ account: String) {
        // Remove from both keychains so a delete is total (also clears any un-migrated legacy copy).
        if useDataProtection {
            SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        }
        SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
    }

    /// One-time capability check: try to add (then remove) a throwaway item to the data-protection
    /// keychain. Adding the app's own item never prompts. Returns false (→ legacy keychain) if the
    /// build lacks the entitlement, so we never break saving on unusual signing setups.
    private static func probeDataProtectionKeychain() -> Bool {
        let probeAccount = "wallet-dp-capability-probe"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data([0x01])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemDelete(base as CFDictionary)
            return true
        }
        Log.security.debug("WalletKeychain: data-protection keychain unavailable (OSStatus \(status, privacy: .public)); using legacy keychain")
        return false
    }
}
