//
//  Edition.swift
//  Searxly
//
//  Compile-time product edition. The base "Searxly" app and the locked, local-only
//  "Searxly Maximum" app share ONE codebase and ONE Xcode project; they differ only by the
//  `MAXIMUM_EDITION` compilation condition, which is set on the SearxlyMaximum target's build
//  configuration (exactly like `DEBUG`). This enum is the single source of truth every feature
//  reads to fork behaviour.
//
//  Prefer `Edition.isMaximum` at call sites over sprinkling `#if MAXIMUM_EDITION` across the app:
//  a plain Bool keeps BOTH targets compiling the same code (so a change to one can't silently
//  break the other), and the base app's behaviour is provably unchanged because `isMaximum` is a
//  constant `false` there — the optimizer drops the Maximum-only branches entirely.
//
//  What "Searxly Maximum" is:
//    • Maximum Privacy locked ON — always `.maximum` + Tor, non-downgradable (see PrivacyManager).
//    • Every off-device surface removed — Managed VPN, Cloud AI, Crypto Wallet, Feedback webhook.
//      (In v1 these stay compiled but are unreachable: no entry points, and PrivacyGate already
//      hard-blocks their egress in Maximum. Dropping them from the binary is a later hardening.)
//    • Integrated AI chat (on-device + cloud) has been removed from both editions in favour of
//      native agentic tools that a user's own local AI can call. No chat model ships anywhere.
//    • Paid, purchased on the website (Brave-style). Licensing is intentionally NOT wired yet.
//

import Foundation

// `nonisolated` on both members: this is a compile-time constant, and reading it must work from the
// `nonisolated` egress choke points (e.g. NetworkEgressLedger.record) as well as the main actor. Without
// this, the project's default main-actor isolation (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor) makes them
// main-actor-isolated and unreachable from those nonisolated call sites. A constant Bool/String is
// trivially Sendable, so nonisolated access is safe.
enum Edition {
    #if MAXIMUM_EDITION
    /// True only in the "Searxly Maximum" build.
    nonisolated static let isMaximum = true
    #else
    nonisolated static let isMaximum = false
    #endif

    /// User-facing product name for this edition (About window, onboarding headline, etc.).
    nonisolated static var appName: String { isMaximum ? "Searxly Maximum" : "Searxly" }
}
