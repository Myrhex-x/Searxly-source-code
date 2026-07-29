//
//  SettingsSearch.swift
//  Searxly
//
//  Spotlight-style search across all of Settings (Searxly Maximum). A professional tool has too
//  many controls to browse — the search field at the top of the Settings window matches against
//  every setting's name, plain-language keywords, and category, and one click (or Return) jumps to
//  the pane that owns it.
//
//  The index is hand-curated rather than generated: each entry carries the words a person would
//  actually type ("wipe", "panic", "fingerprint", "kill switch"), not just the label on the toggle.
//

import SwiftUI

/// Publishes the search field's bounds so the shell can anchor the results popup directly beneath it
/// (rather than centering the popup in the content area, which drifts off the field).
struct SearchFieldBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - Index

struct SettingsSearchEntry: Identifiable {
    let id = UUID()
    /// The setting's display name, as it appears in its pane.
    let title: String
    /// One line locating/explaining it — shown under the title in results.
    let detail: String
    /// Everything a person might type to find it (lowercase).
    let keywords: [String]
    /// The pane that owns it.
    let category: SettingsCategory
}

enum SettingsSearchIndex {

    /// Ranked matches for a query: title-prefix first, then title-contains, then keyword/detail hits.
    static func search(_ query: String) -> [SettingsSearchEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        var prefix: [SettingsSearchEntry] = []
        var contains: [SettingsSearchEntry] = []
        var keyword: [SettingsSearchEntry] = []
        for entry in entries {
            let title = entry.title.lowercased()
            if title.hasPrefix(q) {
                prefix.append(entry)
            } else if title.contains(q) {
                contains.append(entry)
            } else if entry.keywords.contains(where: { $0.contains(q) })
                        || entry.detail.lowercased().contains(q)
                        || entry.category.rawValue.lowercased().contains(q) {
                keyword.append(entry)
            }
        }
        return Array((prefix + contains + keyword).prefix(8))
    }

    /// The full curated index. Maximum-edition entries only exist in Maximum; base-only surfaces
    /// (VPN, wallet, feedback) only exist in the base app — mirroring the sidebar exactly, so
    /// search can never navigate to a pane that isn't there.
    static let entries: [SettingsSearchEntry] = {
        var all: [SettingsSearchEntry] = [
            // Appearance
            .init(title: "Appearance", detail: "System, light, or dark",
                  keywords: ["theme", "dark mode", "light mode", "color scheme"], category: .appearance),
            .init(title: "Reduce liquid glass", detail: "Flatter chrome, fewer translucency effects",
                  keywords: ["glass", "transparency", "flat", "performance", "accessibility"], category: .appearance),

            // Privacy & Data
            .init(title: "Privacy Mode", detail: "The protection ladder and egress lane",
                  keywords: ["maximum privacy", "protection", "tor", "vpn", "ip address", "hide ip"], category: .privacy),
            .init(title: "Browsing history", detail: "Whether Searxly remembers visited pages",
                  keywords: ["history", "remember", "visited", "forget"], category: .privacy),
            .init(title: "Private tabs by default", detail: "New tabs open private",
                  keywords: ["private", "incognito", "new tab"], category: .privacy),
            .init(title: "SafeSearch & content filtering", detail: "Ad and tracker blocking, SafeSearch",
                  keywords: ["adblock", "ads", "trackers", "blocking", "safesearch", "filter"], category: .privacy),
            .init(title: "Link & request privacy", detail: "Strip tracking params, Global Privacy Control, HTTPS-only",
                  keywords: ["tracking", "utm", "fbclid", "gpc", "global privacy control", "https", "link cleaning", "https-only"], category: .privacy),
            .init(title: "Warn about dangerous sites", detail: "Offline phishing & malware site warnings — no URL leaves your Mac",
                  keywords: ["phishing", "malware", "dangerous", "safe browsing", "scam", "warning", "blocklist"], category: .privacy),
            .init(title: "Encrypt local data at rest", detail: "Encrypts history and app data on this Mac",
                  keywords: ["encryption", "at rest", "recovery code", "protect data"], category: .privacy),
            .init(title: "Clear browsing data", detail: "Wipe history, cookies, cache",
                  keywords: ["clear", "wipe", "delete", "erase", "cookies", "cache", "panic"], category: .privacy),
            .init(title: "Default browser & import", detail: "Make Searxly the default; import bookmarks",
                  keywords: ["default browser", "import", "bookmarks", "safari", "chrome"], category: .privacy),

            // App Security
            .init(title: "App Lock", detail: "Lock Searxly behind Touch ID / password, auto-lock on idle",
                  keywords: ["lock", "touch id", "biometric", "idle", "auto-lock", "password"], category: .security),
            .init(title: "Backup & restore", detail: "Encrypted backup of app data",
                  keywords: ["backup", "restore", "export", "migrate"], category: .security),

            // Tor
            .init(title: "Tor & onion services", detail: "Onion routing, circuits, .onion sites",
                  keywords: ["tor", "onion", "circuit", "anonymity", "new identity"], category: .tor),

            // Search
            .init(title: "Search engines & language", detail: "Engines, region, language, suggestions",
                  keywords: ["engine", "google", "bing", "language", "region", "suggestions", "knowledge panel"], category: .search),
            .init(title: "SearXNG instances", detail: "The local metasearch instance powering results",
                  keywords: ["searxng", "instance", "metasearch", "local search"], category: .instances),

            // Features
            .init(title: "Agentic tools", detail: "Connect AI apps like Claude or LM Studio to Searxly",
                  keywords: ["mcp", "ai", "agent", "tools", "automation", "claude", "lm studio", "connect", "server"], category: .agenticTools),
            .init(title: "Performance", detail: "Memory, cache, and speed options",
                  keywords: ["performance", "memory", "speed", "cache"], category: .performance),

            // Support
            .init(title: "Support", detail: "Open or track a support ticket at support.searxly.app",
                  keywords: ["support", "help", "ticket", "contact", "problem", "issue", "assistance"], category: .support),

            // About
            .init(title: "About Searxly", detail: "Version, licenses, acknowledgements",
                  keywords: ["version", "about", "license", "credits", "update"], category: .about),

            // Legal
            .init(title: "Legal", detail: "Privacy Policy and Terms of Service",
                  keywords: ["legal", "privacy policy", "terms", "terms of service", "data", "gdpr", "no logs"], category: .legal),
        ]

        if Edition.isMaximum {
            all += [
                // Password vault (Maximum exclusive)
                .init(title: "Password vault", detail: "Saved logins, autofill, health report, CSV export",
                      keywords: ["passwords", "logins", "autofill", "credentials", "vault", "csv", "breach"], category: .passwords),
                .init(title: "Security Status", detail: "Live posture readouts at the top of Privacy & Data",
                      keywords: ["status", "dashboard", "posture", "readout", "instrument"], category: .privacy),
                .init(title: "Security Level", detail: "Standard / Safer / Safest — the exploit-surface slider",
                      keywords: ["safest", "safer", "javascript", "jit", "exploit", "slider", "lockdown"], category: .privacy),
                .init(title: "Privacy Self-Test", detail: "Verifies the live posture end to end, including the exit IP",
                      keywords: ["self test", "verify", "check", "exit ip", "leak test"], category: .privacy),
                .init(title: "Network Ledger", detail: "Every outbound request and the lane it used",
                      keywords: ["ledger", "egress", "requests", "traffic", "log", "audit"], category: .privacy),
                .init(title: "Tor bridges", detail: "obfs4 and Snowflake for networks that block Tor",
                      keywords: ["bridge", "obfs4", "snowflake", "censorship", "blocked network"], category: .privacy),
                .init(title: "Amnesic mode", detail: "RAM-only sessions — nothing survives quitting",
                      keywords: ["amnesia", "amnesic", "ram", "no trace", "tails", "forget", "session"], category: .privacy),
                .init(title: "Uniform locale", detail: "Pins the Accept-Language header to en-US",
                      keywords: ["locale", "language header", "accept-language", "fingerprint", "en-us"], category: .privacy),
                .init(title: "Exclude windows from screen capture", detail: "Windows render black in recordings and shared screens",
                      keywords: ["screenshot", "screen capture", "recording", "zoom", "teams", "share"], category: .privacy),
                .init(title: "Secure keyboard entry", detail: "Blocks keystroke taps while the address bar is focused",
                      keywords: ["keyboard", "keylogger", "keystroke", "secure input", "typing"], category: .privacy),
                .init(title: "Kill switch", detail: "Fail-closed: no protection, no traffic",
                      keywords: ["kill switch", "fail closed", "block", "leak"], category: .privacy),
                .init(title: "Fingerprint defenses", detail: "Canvas / WebGL / audio scrambling, letterboxing, timers",
                      keywords: ["fingerprint", "farbling", "canvas", "webgl", "letterbox", "tracking"], category: .privacyReport),
                .init(title: "Build provenance", detail: "Exact versions of the app and every bundled runtime",
                      keywords: ["build", "provenance", "tor version", "runtime", "supply chain", "verify"], category: .about),
            ]
        }
        return all
    }()
}

// MARK: - Search field + results

/// The Spotlight-style field that lives in the Settings header. Owns its query state; publishes
/// navigation through `onNavigate`.
struct SettingsSearchField: View {
    @Binding var query: String
    /// Return key — the shell opens the top-ranked result.
    var onSubmit: () -> Void = {}
    /// Focus is owned by the shell so ⌘F can drive it; the field just binds to it.
    @FocusState.Binding var focused: Bool

    private let ember = Color(red: 1.0, green: 0.53, blue: 0.16)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(focused ? ember.opacity(0.9) : SettingsTheme.textSecondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsTheme.textPrimary)
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand { query = "" ; focused = false }
            if query.isEmpty {
                // Keyboard hint — reads as a real Spotlight-style field, and tells power users the shortcut.
                Text("⌘F")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 250)
        // Dark liquid glass: a dark tint UNDER real Liquid Glass, so it keeps our dark look while
        // gaining the glass refraction (same recipe as the wallet's glass cards).
        .background {
            let cap = Capsule()
            cap.fill(Color.black.opacity(0.34)).searxlyGlass(.regular, in: cap)
        }
        // Quiet border; on focus it warms to a thin ember keyline — no big glow.
        .overlay(
            Capsule().strokeBorder(focused ? ember.opacity(0.55) : Color.white.opacity(0.12),
                                   lineWidth: 1)
        )
        .anchorPreference(key: SearchFieldBoundsKey.self, value: .bounds) { $0 }
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// The floating results panel. Rendered by the Settings shell as an overlay under the header so it
/// floats above both columns, Spotlight-style.
struct SettingsSearchResults: View {
    let query: String
    let onSelect: (SettingsSearchEntry) -> Void

    private var results: [SettingsSearchEntry] { SettingsSearchIndex.search(query) }

    var body: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if results.isEmpty {
                    Text("No settings match “\(query)”")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ForEach(results) { entry in
                        SettingsSearchResultRow(entry: entry) { onSelect(entry) }
                    }
                }
            }
            .padding(7)
            .frame(width: 420)
            // Dark liquid glass — a dark tint under real Liquid Glass, matching the search field.
            .background {
                let s = RoundedRectangle(cornerRadius: 16, style: .continuous)
                s.fill(Color.black.opacity(0.5)).searxlyGlass(.regular, in: s)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.5), radius: 26, y: 13)
        }
    }
}

private struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SettingsTheme.fillSubtle)
                        .frame(width: 26, height: 26)
                    Image(systemName: entry.category.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    Text(entry.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(entry.category.localizedTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? SettingsTheme.fillStrong : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in DispatchQueue.main.async { hover = h } }
    }
}
