//
//  WebPasskeyDirectory.swift
//  Searxly
//
//  Read-only view of the passkeys the SYSTEM holds for a given site — iCloud Keychain plus any
//  third-party passkey provider the user has enabled (1Password, Bitwarden, …).
//
//  Why this exists: WKWebView already handles WebAuthn natively, so passkey sign-in works with
//  zero app code. But the vault had no idea those passkeys existed, so it kept presenting stored
//  passwords as the only credential for a site. This closes that gap — it lets the passwords pill
//  show "you also have a passkey here", and lets vault health point out passwords that a passkey
//  has already made redundant.
//
//  WHAT THIS CANNOT DO: read passwords out of Apple Passwords / iCloud Keychain. No API exists —
//  not for us, not for Chrome, not for anyone but Safari. This returns passkey METADATA only
//  (username, relying party, credential id, provider name). No secrets, no private keys, ever.
//
//  Gated on the restricted `com.apple.developer.web-browser.public-key-credential` entitlement,
//  which Apple grants PER BUNDLE ID. It is live for com.myrhex.Searxly (base) but not yet for
//  com.myrhex.SearxlyMaximum — and an unsigned/ad-hoc build carries no entitlements at all. Every
//  path here therefore degrades to "unavailable" rather than assuming success, so the UI simply
//  hides the passkey surfaces wherever the entitlement isn't in force.
//

import Foundation
import AuthenticationServices
import os

/// One passkey the system holds for a site. Metadata only.
struct WebPasskeySummary: Identifiable, Equatable, Sendable {
    /// Base64 of the credential ID — stable, and unique per credential.
    let id: String
    /// The account name the passkey was saved under.
    let name: String
    /// A user-assigned title, when they've set one.
    let customTitle: String?
    let relyingParty: String
    /// Localized name of whichever provider holds it ("iCloud Keychain", "1Password", …).
    let providerName: String

    /// What to show in a list row: the user's own title wins, otherwise the account name.
    var displayName: String { customTitle?.isEmpty == false ? customTitle! : name }
}

@MainActor
@Observable
final class WebPasskeyDirectory {
    static let shared = WebPasskeyDirectory()

    enum Access: Equatable {
        /// Entitlement missing, or the platform refused — no passkey surfaces at all.
        case unavailable
        /// Entitlement present, user hasn't been asked yet.
        case notDetermined
        /// User declined. Only recoverable through System Settings, so never re-prompt.
        case denied
        case authorized
    }

    private static let log = Logger(subsystem: "com.myrhex.Searxly", category: "webpasskeys")

    /// App-side switch, independent of the system permission, so the surfaces can be hidden
    /// without revoking access (and so Maximum users can turn it off without a trip to Settings).
    private let displayEnabledKey = "WebPasskeys.DisplayEnabled"

    private(set) var access: Access = .notDetermined

    /// Cached lookups keyed by relying-party id. Passkeys change rarely and each lookup is an XPC
    /// round-trip, so results are held for the session and invalidated explicitly.
    private var cache: [String: [WebPasskeySummary]] = [:]

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()

    private init() {
        refreshAccess()
    }

    var displayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: displayEnabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: displayEnabledKey)
            if !newValue { cache.removeAll() }
        }
    }

    /// True when passkey surfaces should render at all.
    var isActive: Bool { access == .authorized && displayEnabled }

    /// Whether it's worth offering the user an "enable" affordance. False once denied, because the
    /// system will not prompt a second time and a dead button is worse than no button.
    var canRequestAccess: Bool { access == .notDetermined }

    // MARK: - Authorization

    func refreshAccess() {
        access = Self.map(manager.authorizationStateForPlatformCredentials)
    }

    /// Prompts for access. MUST be called only from an explicit user action — the system asks once
    /// and a denial is effectively permanent, so an unprompted request at launch would quietly
    /// burn the feature for that user.
    @discardableResult
    func requestAccess() async -> Access {
        guard access == .notDetermined else { return access }
        let state = await withCheckedContinuation { continuation in
            manager.requestAuthorizationForPublicKeyCredentials { state in
                continuation.resume(returning: state)
            }
        }
        access = Self.map(state)
        Self.log.notice("Web passkey access is now \(String(describing: self.access), privacy: .public)")
        return access
    }

    private static func map(
        _ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> Access {
        switch state {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        // A future state we don't recognise is treated as "no passkey surfaces" rather than
        // optimistically shown — the failure mode of guessing wrong is a broken-looking UI.
        @unknown default: return .unavailable
        }
    }

    // MARK: - Lookup

    /// Passkeys the system holds for `domain`. Empty when inactive, unknown, or genuinely none.
    ///
    /// `domain` should already be normalized (see `PasswordVaultManager.normalizeDomain`) since
    /// WebAuthn relying-party ids are bare registrable domains — "github.com", never
    /// "https://github.com/login" or "www.github.com".
    func passkeys(forDomain domain: String) async -> [WebPasskeySummary] {
        guard isActive, !domain.isEmpty else { return [] }
        if let cached = cache[domain] { return cached }

        let credentials = await manager.platformCredentials(forRelyingParty: domain)
        let summaries = credentials.map {
            WebPasskeySummary(
                id: $0.credentialID.base64EncodedString(),
                name: $0.name,
                customTitle: $0.customTitle,
                relyingParty: $0.relyingParty,
                providerName: $0.providerName
            )
        }
        cache[domain] = summaries
        return summaries
    }

    /// Cached answer without triggering a lookup — for synchronous view code that shouldn't block.
    /// nil means "not looked up yet", which callers render as absent rather than as zero.
    func cachedPasskeys(forDomain domain: String) -> [WebPasskeySummary]? {
        guard isActive else { return nil }
        return cache[domain]
    }

    func invalidateCache() {
        cache.removeAll()
    }
}
