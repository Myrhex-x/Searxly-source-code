# Searxly

Searxly is a privacy-respecting native macOS browser built with SwiftUI and WebKit.  
**Core feature:** It runs a fully local, private SearXNG instance on *your own Mac* — a signed SearXNG runtime is bundled right inside the app, so search happens entirely on your machine with no accounts and no telemetry.

**Current status (as of this build):**
- Local SearXNG (native, bundled inside the app) is the primary, fully supported private search experience.
- A self-custody Base L2 wallet (BIP-39/32, real EIP-1559 signing) is included in `Searxly/Wallet/`.
- On-device / local AI assistance lives in `Searxly/LocalAI/`.
- The ad-block engine and the VPN / WireGuard implementation are **not** included in this public source (see "What's omitted" below).

This repository contains source code for transparency, code review, and learning. It is **not** a downloadable or buildable application — see "What's omitted".

## What's in this repository

- Complete browser UI and logic (SwiftUI + WebKit)
- Local SearXNG lifecycle and configuration handling (the hero feature — see `LocalSearxngManager.swift` and `LocalSearxng/`)
- Self-custody Base L2 wallet (`Searxly/Wallet/`) + crypto unit tests (`WalletCryptoTests/`)
- On-device / local AI assistance (`Searxly/LocalAI/`)
- Supporting infrastructure (persistence, privacy controls, tab hibernation, premium design tokens, etc.)

## What's omitted (intentionally private)

To keep this a source-for-review repository rather than a downloadable app, the following are excluded via `.gitignore` and are **not** part of the public tree:

- **App entry point** (`Searxly/App/SearxlyApp.swift`) — without it a clone won't build a runnable app.
- **Ad-block engine** (`Searxly/AdBlocker/`, filter lists, cosmetic configs).
- **VPN / WireGuard implementation** (`Searxly/VPN/`, `SearxlyWireGuardTunnel/`, and the VPN UI).
- **Build outputs / signed binaries** — no `.app` or `.dmg` is published in the repo.
- **Signing identity** — `DEVELOPMENT_TEAM` is blanked in the project; set your own to build.

The Xcode project still *references* these omitted files, so a fresh clone will show missing-file references and will not compile into a shippable app. This is intentional: it gives visibility into the surrounding implementation while official, code-signed releases go through proper distribution channels. The maintainer keeps the complete working copy privately.


## License

**Source-available — noncommercial.** Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

You may view, run, modify, and share Searxly for **noncommercial** purposes only (personal use, study, hobby projects, research, nonprofits, etc.). **Commercial use is not permitted.** This is a source-available license, not an OSI "open source" license.

Copyright © 2026 Myrhex-x. All rights reserved except as granted by the license. The **"Searxly" name, logo, and brand** are *not* licensed for reuse, and the `$SEARXLY` token is unaffected by this license. For commercial licensing, contact the maintainer via the official **@Searxly** account on X.

## Community & Support

Ongoing development is supported by the community through the **$SEARXLY** token on Base.

- Contract address: `0x0fdc79b868bc4a6295cd94397f61890f68c38ba3`
- All updates and the CA are posted on the official **@Searxly** account on X.

Do your own research. All funds go directly to project development.

## Current Feature Status

- **Local SearXNG**: Fully automatic. One-click in onboarding or Settings → Instances. Creates `~/searxng-local/`, injects a strong secret, deploys the premium Searxly theme, launches the bundled SearXNG process, and waits for the instance to be ready.
- **VPN**: The WireGuard implementation is omitted from this public source (see "What's omitted"). In maintainer builds it requires a paid Apple Developer membership + a provisioning profile with the `packet-tunnel-provider` capability.
- **Wallet**: A self-custody Base L2 wallet is included (`Searxly/Wallet/`). Keys never leave the device — the seed is encrypted in the macOS Keychain (AES-GCM + PBKDF2, device-only, never iCloud-synced).

## Local SearXNG (User Side)

Nothing to install. SearXNG ships inside Searxly as a signed, self-contained runtime, so there are no external dependencies — the app starts your private instance on `127.0.0.1` by itself.

The bundled `LocalSearxng/` folder (configs + premium theme) is copied at runtime into the user's home directory. A strong random `secret_key` is generated automatically — never committed.
