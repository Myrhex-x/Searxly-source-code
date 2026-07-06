//
//  PasswordVaultManager+Health.swift
//  Searxly
//
//  Bridges the offline PasswordHealth engine to the vault. All analysis is local — loading each
//  secret requires the vault to be unlocked, and nothing is ever sent off the device.
//

import Foundation

extension PasswordVaultManager {

    /// Per-entry health reports, keyed by entry id. Requires the vault to be UNLOCKED (each secret is
    /// read from the secure store). Returns an empty map when locked or no secrets are readable, so
    /// callers degrade gracefully rather than surfacing misleading results.
    func healthReports() -> [UUID: PasswordHealth.Report] {
        // ENFORCE the unlock gate. Keychain items are `WhenUnlockedThisDeviceOnly`, so they're
        // readable whenever the Mac is unlocked regardless of the VAULT lock — analyzing them here
        // while the vault is "locked" would quietly defeat the lock (e.g. an "N at-risk" count
        // leaking without biometric/passphrase). `password(for:)` guards this; health must too.
        guard isVaultUnlocked else { return [:] }
        let items = entries.compactMap { entry -> (id: UUID, password: String)? in
            guard let password = PasswordVaultSecureStore.loadPassword(for: entry.id), !password.isEmpty
            else { return nil }
            return (entry.id, password)
        }
        return PasswordHealth.analyze(items)
    }

    /// How many entries should be reviewed (reused, weak, or known-common). 0 when locked.
    func atRiskCount() -> Int {
        healthReports().values.filter { $0.atRisk }.count
    }
}
