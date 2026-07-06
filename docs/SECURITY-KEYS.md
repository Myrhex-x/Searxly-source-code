# Hardware security keys (FIDO2 / YubiKey) — setup

Searxly can require a physical security key (YubiKey or any FIDO2 key) as a **second factor** on top of
Touch ID for **App Lock, the Password Vault, and the Wallet**. Built on Apple's AuthenticationServices,
works with any FIDO2 key, fully offline (the app is its own relying party).

The key is an **unlock / decrypt factor only** — it never signs wallet transactions (that stays with
Ledger; a YubiKey can't sign Ethereum/secp256k1 anyway).

**Relying-party ID: `www.searxly.app`** (your primary domain — the apex `searxly.app` 308-redirects to
`www`, which Apple's associated-domains CDN won't follow, so we point at `www` directly).

## Status

- Code: `Searxly/Services/SecurityKeyManager.swift`, UI in `SecurityKeySettingsSection.swift`
  (Settings → App Security). Wired into App Lock as a second factor.
- **Off by default**; the Settings section only appears in **Developer Mode** until you finish the
  entitlement step below. After that, remove the `DeveloperSettings.shared.isEnabled` gate in
  `SecurityKeySettingsSection` to expose it to everyone.

## ✅ AASA file — DONE (deployed)

Already created + deployed to the website (`searxly-website` repo → `/.well-known/apple-app-site-association`,
committed to `main`, live on Vercel). Verified:

```
$ curl -sSI https://www.searxly.app/.well-known/apple-app-site-association
HTTP/2 200 ; content-type: application/json
{ "webcredentials": { "apps": ["KKRU446268.com.myrhex.Searxly"] } }
```

Nothing to do here unless the Team ID or bundle ID changes (then update that file + redeploy).

## ⬜ Entitlement — your step (you have the Developer Program)

1. In Xcode → Searxly target → Signing & Capabilities → **+ Capability → Associated Domains**.
2. Add: `webcredentials:www.searxly.app`.
   (Equivalently, uncomment the `com.apple.developer.associated-domains` block in
   `Searxly/Searxly.entitlements` — already stubbed there.)
3. Make sure the App ID on developer.apple.com has **Associated Domains** enabled and the provisioning
   profile is regenerated (automatic signing usually handles this).

## Enabling + testing

1. Build **signed with your team** (associated domains only validate on a properly provisioned build).
2. Settings → App Security → **Security keys (experimental)** → turn on → **Add a security key** (insert
   + tap). Enroll **two** keys (a backup is required before any "Require for…" toggle arms).
3. Turn on "Require for App Lock", lock the app, confirm unlock now needs **Touch ID + a key tap**.

## Recovery (already wired)

- **Backup key:** enroll ≥2; either unlocks. Dropping below 2 auto-disarms the requirement.
- **Lost all keys:** the App Lock recovery-code flow ("Use recovery code") is a deliberate escape hatch.
  For the **wallet**, a lost key just means re-importing from the 12-word phrase.

## Roadmap

- **Phase 2:** wire the gate into the Vault + Wallet unlock paths
  (`assertIfRequiredForVault()` / `assertIfRequiredForWallet()` already exist).
- **Phase 3:** cryptographic **binding** — mix a YubiKey HMAC-SHA1 challenge-response secret into the
  seed/vault encryption key (needs USB/CCID entitlements + a strict backup-key policy).
