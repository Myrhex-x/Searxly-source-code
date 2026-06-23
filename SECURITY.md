# Security Policy

**Searxly** is a privacy-respecting native macOS browser powered by a bundled native local SearXNG instance (no Docker), with an included self-custody Base L2 wallet. This document describes the current security model, known limitations, and how to report vulnerabilities. (The VPN/WireGuard and ad-block implementations are kept in a private working copy and are not part of this public source.)

## Supported Versions

This repository provides **source code only**. Official pre-built, code-signed, and notarized application bundles are not yet distributed here (see the [README](README.md) for distribution plans). Security-relevant changes are tracked on the `main` branch.

## Reporting a Vulnerability

If you identify a security vulnerability:

1. **Preferred**: Use GitHub's private [Security Advisory](https://github.com/Myrhex-x/Searxly-source-code/security/advisories/new) feature to report it confidentially.
2. Alternatively, open a GitHub issue with the `security` label (or contact the maintainer via the official project X account for sensitive matters).

Please include as much detail as possible (steps to reproduce, affected code paths, potential impact). Do not disclose publicly until a fix or mitigation is available.

## Current Security Posture & Known Limitations

### App Sandbox
- **Status**: Enabled. The app ships with the App Sandbox entitlement (`com.apple.security.app-sandbox`) in `Searxly/Searxly.entitlements`, alongside Hardened Runtime.
- **How privileged operations work under the sandbox**: Spawning and supervising the bundled native SearXNG (Python) process and reading/writing `~/searxng-local/` are delegated to the separate `SearxlyHelper` XPC service (unsandboxed), so the main sandboxed app never touches those paths directly.
- **Compensating controls**:
  - Hardened Runtime is enabled.
  - Local secrets/data use Keychain + CryptoKit (AES-GCM) at rest.
  - WebKit content processes run with scoped, individually documented temporary exceptions (see the rationale comments in the entitlements file).

### VPN / Packet Tunnel Provider
- **Status**: Real system-wide WireGuard VPN requires a **paid Apple Developer Program** membership and a provisioning profile that includes the `packet-tunnel-provider` capability. The relevant entitlement (`com.apple.developer.networking.networkextension`) is left commented out in `Searxly/Searxly.entitlements` so the project builds on free/personal Apple ID teams.
- **Not in this public source**: The WireGuard adapter, tunnel provider, configuration handling, and VPN UI are **omitted** from this repository (see the README "What's omitted" section). They remain in the maintainer's private working copy.

### Wallet (self-custody)
- The Base L2 wallet is fully self-custodial: the BIP-39 seed and any imported private keys never leave the device.
- The seed is AES-GCM encrypted under a key derived from the user's PIN via PBKDF2-SHA256 (200k rounds) with a per-wallet random salt, stored device-only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never iCloud-synced).
- A 6-digit PIN is rate-limited (lockout after repeated failures); biometric unlock is gated behind the Secure Enclave (`.biometryCurrentSet`). See `Searxly/Wallet/WalletKeychain.swift`.

### Secrets, Credentials & Configuration
- **Design**: 
  - Configuration templates live in `*.example` files (e.g. `LocalSearxng/searxng/settings.yml.example` and the copy in `local-searxng/`).
  - Placeholder values such as `secret_key: "YOUR_SECRET_KEY_HERE"` are used.
  - The app's `LocalSearxngManager` (or manual copy/rename) produces the real `settings.yml` at runtime.
  - `.gitignore` explicitly protects `settings.yml`, `searxng-local/`, `*.log`, and user data directories.
- **No real secrets are ever committed** to this public repository.
- **User responsibility**: The app generates a strong random `secret_key` automatically on first setup. If you build a `settings.yml` by hand, replace the placeholder `secret_key` with a strong random value (`openssl rand -hex 32` is recommended). Never commit a file named `settings.yml` containing a real key.

### Privacy & Data Handling
- **Local-first by design**: All searches are routed through the user's own local SearXNG instance. No queries are sent to third-party public instances by default.
- **No built-in telemetry or analytics**.
- Private browsing uses non-persistent `WKWebsiteDataStore`.
- Optional at-rest encryption for history/bookmarks/etc. via CryptoKit + Keychain.
- Favicon and media loading can be proxied through SearXNG when image_proxy is enabled.
- The app does not phone home or exfiltrate data.

### Code Signing, Notarization & Distribution
- **Current builds**: Use Automatic signing. Network extension entitlements are left commented out, and the VPN implementation is not part of the public source.
- **QA / Tester builds**: Use the provided `scripts/build-qa.sh`. It produces archived + exported builds and attempts notarization + stapling. See the script and the updated README section "Building for QA Testers & Distribution".
- **Source builds**: Limited to personal Apple Development certificates. Hardened Runtime is enabled; App Sandbox is enabled, with the `SearxlyHelper` XPC service spawning the bundled native SearXNG process + performing `~/searxng-local` writes on the sandboxed app's behalf. `DEVELOPMENT_TEAM` is blanked in the project — set your own to build.
- **Future official releases**: Will use Developer ID + full notarization pipeline + (when re-enabled) proper provisioning for any system extensions.
- Recommendation: Run the QA script for any builds you hand to others. Ad-hoc builds require right-click Open on recipient Macs.

### Local SearXNG & Network
- Runs a pinned, bundled native SearXNG (Python) — shipped inside the app at `Resources/searxng-runtime/`, no external image or daemon.
- The instance serves on port 8080 (overridable via the `SEARXNG_PORT` / `SEARXNG_BIND_ADDRESS` env vars the helper passes at launch).
- Defaults to binding `127.0.0.1` (localhost-only); LAN exposure is an opt-in Developer-Mode toggle.
- Keep macOS up to date.

### Dependencies
- Relies on Apple’s WebKit, system frameworks, the bundled SearXNG Python runtime, and standard Swift packages.
- No third-party analytics or crash-reporting SDKs are embedded.

## Security Hardening Roadmap
- Continue tightening the App Sandbox + `SearxlyHelper` XPC boundary toward least privilege.
- Full production-ready entitlements and signing pipeline.
- Optional security update mechanism (user-opt-in).
- Independent code review / audit of the wallet and local data persistence layers (once v0.1 stabilizes).

## Disclaimer
Searxly is an individual learning and transparency project under active development. While privacy and security are core priorities, the source-only distribution model (no published binaries; key components kept private) means that users reviewing this repository should understand the trade-offs involved. The project is provided “as is” for educational and contributory purposes.

For any questions about the security design or architecture, open an issue tagged `security` or `question`.

---