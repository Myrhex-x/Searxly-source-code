//
//  LocalSearxngManager+ConfigPatching
//  Searxly
//
//  Patches the on-disk SearXNG settings.yml / limiter.toml to stay compatible with the bundled
//  SearXNG and Searxly's local-private defaults. The runtime is a bundled native process.
//

import Foundation
import SwiftUI
import Observation
import Security

extension LocalSearxngManager {

    /// Brings the on-disk SearXNG config in line with the bundled runtime + local-private defaults:
    /// sets bind/port, removes an incompatible plugins dict, and fixes the limiter schema. Safe and
    /// idempotent — runs before each launch.
    func ensureSearxngConfigured() async {
        await ensureSettingsYmlBindPort()
        await ensureNativeThemePathsRemoved()
        await ensureWebEnginesUpgradedIfNeeded()
        await ensureSearchTuningConfigIfNeeded()
        await ensurePluginsSectionCompatibleIfNeeded()
        await ensureLimiterTomlCompatibleIfNeeded()
    }

    /// SearXNG locales Searxly registers so the macOS system region (en-US, fr-FR, …) survives instead
    /// of being stripped to its base language. Mirrors `settings.yml.example`.
    static let searchLanguagesBlock = """
  languages:
    - all
    - en
    - en-US
    - en-GB
    - en-CA
    - en-AU
    - fr
    - fr-FR
    - fr-CA
    - de
    - de-DE
    - es
    - es-ES
    - es-MX
    - it
    - it-IT
    - pt
    - pt-PT
    - pt-BR
    - nl
    - nl-NL
    - sv
    - sv-SE
    - da
    - da-DK
    - fi
    - fi-FI
    - pl
    - pl-PL
    - ru
    - ru-RU
    - tr
    - tr-TR
    - ar
    - ar-SA
    - ja
    - ja-JP
    - ko
    - ko-KR
    - zh
    - zh-CN
    - zh-TW
    - hi
    - id
    - id-ID
    - uk
    - cs
    - cs-CZ
    - ro
    - ro-RO
    - hu
    - hu-HU
    - el
    - el-GR
    - he
    - th
    - th-TH
    - vi
"""

    /// Tunes the on-disk config so search returns more results in the right language. Two fixes:
    ///  1. Registers region-qualified locales (`search.languages`) so the macOS system region the app
    ///     sends (e.g. en-US) reaches the engines instead of being collapsed to `en` — without this,
    ///     Bing geo-targets by IP and you get results in the wrong language.
    ///  2. Raises the request timeout (3s→5s, +10s cap) and shortens engine suspension times so
    ///     intermittently-blocked engines recover quickly instead of leaving the SERP bing-only.
    /// One-time, idempotent.
    func ensureSearchTuningConfigIfNeeded() async {
        let migrationKey = "Searxly.DidApplySearchTuning2026"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        guard let proxy = HelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              var content = String(data: data, encoding: .utf8) else { return }

        let original = content

        // 1. Engine resilience: timeout + suspension times.
        content = content.replacingOccurrences(of: "request_timeout: 3.0", with: "request_timeout: 5.0")
        if content.contains("# max_request_timeout: 10.0") {
            content = content.replacingOccurrences(of: "# max_request_timeout: 10.0", with: "max_request_timeout: 10.0")
        } else if !content.contains("max_request_timeout:"),
                  let r = content.range(of: "request_timeout: 5.0") {
            content.insert(contentsOf: "\n  max_request_timeout: 10.0", at: r.upperBound)
        }
        content = content.replacingOccurrences(of: "SearxEngineAccessDenied: 180", with: "SearxEngineAccessDenied: 60")
        content = content.replacingOccurrences(of: "SearxEngineCaptcha: 3600", with: "SearxEngineCaptcha: 300")
        content = content.replacingOccurrences(of: "SearxEngineTooManyRequests: 180", with: "SearxEngineTooManyRequests: 60")

        // 2. Region locales: insert a `languages:` list right after `default_lang:` if absent.
        if !content.contains("\n  languages:\n"),
           let regex = try? NSRegularExpression(pattern: #"(?m)^  default_lang:.*$"#),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let r = Range(match.range, in: content) {
            content.insert(contentsOf: "\n" + Self.searchLanguagesBlock, at: r.upperBound)
        }

        guard content != original, let newData = content.data(using: .utf8) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        if await proxy.writeFileAsync(data: newData, toPath: settingsPath) {
            logs.append("✅ Search tuning applied: registered region locales (results now follow your Mac's language/region instead of your IP) + faster engine recovery (timeout 5s, shorter suspensions). Restart SearXNG to apply.")
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            logs.append("⚠️ Could not apply search tuning (XPC write failed)")
        }
    }

    /// Upgrades the general-web engine set on already-provisioned lean installs so search returns more
    /// results and infinite scroll has somewhere to go. The original lean list leaned on bing +
    /// duckduckgo + brave + startpage, but from a residential IP brave/startpage return nothing
    /// (blocked) and duckduckgo doesn't paginate — so the SERP capped at ~20-35 results and scroll
    /// died early. This adds google (the strongest source + reliable deep pagination) plus mojeek and
    /// yahoo, and removes the two dead engines. One-time, idempotent, only touches Searxly-managed
    /// lean lists (detected by the bundled `bing images` entry). Fresh installs already get this set
    /// from `LeanSearxngEngines.block`.
    func ensureWebEnginesUpgradedIfNeeded() async {
        let migrationKey = "Searxly.DidUpgradeWebEngines2026"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        guard let proxy = HelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              var content = String(data: data, encoding: .utf8) else { return }

        // Only migrate Searxly-managed lean lists (has the bundled bing-images entry).
        guard content.contains("  - name: bing images") else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        var changed = false

        // Remove the dead engines (brave, startpage) — whole 3-line block + a trailing blank line.
        for dead in ["brave", "startpage"] {
            let pattern = "(?m)^  - name: \(dead)\\n    engine: \(dead)\\n    shortcut: \\w+\\n\\n?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil {
                content = regex.stringByReplacingMatches(
                    in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
                changed = true
            }
        }

        // Add google ahead of the existing web engines (before the first `- name: bing` block).
        if !content.contains("\n    engine: google\n"),
           let bingRange = content.range(of: "  - name: bing\n    engine: bing\n") {
            content.insert(contentsOf: "  - name: google\n    engine: google\n    shortcut: go\n\n", at: bingRange.lowerBound)
            changed = true
        }

        // Add mojeek + yahoo right after the duckduckgo block.
        let ddgBlock = "  - name: duckduckgo\n    engine: duckduckgo\n    shortcut: ddg\n"
        if let ddgRange = content.range(of: ddgBlock) {
            var additions = ""
            if !content.contains("\n    engine: mojeek\n") {
                additions += "\n  - name: mojeek\n    engine: mojeek\n    shortcut: mjk\n"
            }
            if !content.contains("\n    engine: yahoo\n") {
                additions += "\n  - name: yahoo\n    engine: yahoo\n    shortcut: yh\n"
            }
            if !additions.isEmpty {
                content.insert(contentsOf: additions, at: ddgRange.upperBound)
                changed = true
            }
        }

        guard changed else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        if let newData = content.data(using: .utf8),
           await proxy.writeFileAsync(data: newData, toPath: settingsPath) {
            logs.append("✅ Upgraded web engines (added google, mojeek, yahoo; removed dead brave/startpage) — more results + deeper infinite scroll. Restart SearXNG to apply.")
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            logs.append("⚠️ Could not upgrade web engines (XPC write failed)")
        }
    }

    /// Removes the legacy `ui.static_path` / `ui.templates_path` overrides from settings.yml.
    /// Those pointed at `/etc/searxng/custom/...` (a legacy bind-mount location). In the native runtime
    /// those directories don't exist, and SearXNG's schema validates them as required directories —
    /// a missing path makes it raise `ValueError('Invalid settings.yml')` and exit instantly, which
    /// surfaces in the UI as an endless "Starting local SearXNG…". Searxly renders its own native
    /// SERP from the JSON API, so dropping these lines (SearXNG falls back to its complete built-in
    /// simple theme) is the correct fix. Idempotent — only writes when a stale path is present.
    func ensureNativeThemePathsRemoved() async {
        guard let proxy = HelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              let content = String(data: data, encoding: .utf8) else { return }

        // Matches a `static_path:`/`templates_path:` line that points at the legacy mount path,
        // optionally preceded by its `# Custom ... path` comment line. Both leading spaces and the
        // trailing newline are consumed so the surrounding `ui:` block stays well-formed.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*#.*[Cc]ustom.*path.*\n[ \t]*(?:static_path|templates_path):[ \t]*["']?/etc/searxng/custom/[^"'\n]*["']?[ \t]*\n|^[ \t]*(?:static_path|templates_path):[ \t]*["']?/etc/searxng/custom/[^"'\n]*["']?[ \t]*\n"#,
            options: []
        ) else { return }

        let range = NSRange(content.startIndex..., in: content)
        guard regex.firstMatch(in: content, options: [], range: range) != nil else { return }

        let patched = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
        guard let newData = patched.data(using: .utf8),
              await proxy.writeFileAsync(data: newData, toPath: settingsPath) else {
            logs.append("⚠️ Could not remove stale legacy theme paths from settings.yml (XPC write failed)")
            return
        }
        logs.append("✅ Removed stale legacy theme paths (ui.static_path/templates_path → /etc/searxng/custom) that crashed native SearXNG with 'Invalid settings.yml'. Using the built-in simple theme.")
    }

    /// Ensures settings.yml has a sane localhost bind + the right port. The helper passes the live
    /// bind address via the SEARXNG_BIND_ADDRESS env var (which overrides settings.yml), so this is
    /// just a safe default; the LAN-exposure toggle is honored at launch through that env var.
    func ensureSettingsYmlBindPort() async {
        guard let proxy = HelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              var content = String(data: data, encoding: .utf8) else { return }

        let original = content

        if let regex = try? NSRegularExpression(pattern: #"(bind_address:\s*)["']?[^"'\n]*["']?"#, options: []) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "$1\"127.0.0.1\"")
        }

        if let regex = try? NSRegularExpression(pattern: #"port:\s*\d+"#, options: []) {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "port: 8080")
        }

        guard content != original, let newData = content.data(using: .utf8) else { return }
        _ = await proxy.writeFileAsync(data: newData, toPath: settingsPath)
    }

    func ensurePluginsSectionCompatibleIfNeeded() async {
        let migrationKey = "Searxly.DidFixPluginsDictFormat"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        guard let proxy = HelperClient.shared.proxy() else { return }

        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              let content = String(data: data, encoding: .utf8) else { return }

        guard content.contains("\n  searx.plugins.") else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let startMarker = "\n# Plugin configuration"
        let fallbackStart = "\nplugins:"
        guard let pluginsRange = content.range(of: startMarker) ?? content.range(of: fallbackStart) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let afterPlugins = content[pluginsRange.upperBound...]
        let nextSectionMarkers = ["\n# Configuration of", "\nhostnames:", "\nanswerers:", "\ncustom_themes:"]
        var cutPoint = content.endIndex
        for marker in nextSectionMarkers {
            if let r = afterPlugins.range(of: marker) {
                let idx = content.index(pluginsRange.upperBound,
                                        offsetBy: afterPlugins.distance(from: afterPlugins.startIndex, to: r.lowerBound))
                if idx < cutPoint { cutPoint = idx }
            }
        }

        let fixed = String(content[..<pluginsRange.lowerBound]) + "\n" + String(content[cutPoint...])

        if let newData = fixed.data(using: .utf8),
           await proxy.writeFileAsync(data: newData, toPath: settingsPath) {
            logs.append("✅ Removed incompatible plugins: dict section from settings.yml (requires list format in this SearXNG). SearXNG will use its built-in plugin defaults.")
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            logs.append("⚠️ Could not remove plugins: dict section (XPC write failed)")
        }
    }

    func ensureLimiterTomlCompatibleIfNeeded() async {
        let migrationKey = "Searxly.DidFixLimiterTomlSchema"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        guard let proxy = HelperClient.shared.proxy() else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let tomlPath = projectFolderURL.appendingPathComponent("searxng/limiter.toml").path
        guard await proxy.fileExistsAsync(atPath: tomlPath),
              let data = await proxy.readFileAsync(atPath: tomlPath),
              let content = String(data: data, encoding: .utf8) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        guard content.contains("[botdetection]") && content.contains("ipv4_prefix") else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        let fixed = """
# Permissive limiter config for local private use.
# Works together with server.limiter=false in settings.yml.
# Schema must match the bundled SearXNG (2025.2.12): ipv4_prefix/ipv6_prefix live under [real_ip].

[real_ip]
ipv4_prefix = 32
ipv6_prefix = 48
x_for = 1

[botdetection.ip_limit]
filter_link_local = false
link_token = false

[botdetection.ip_lists]
block_ip = []

pass_ip = [
  '127.0.0.0/8',
  '::1',
  '192.168.0.0/16',
  '10.0.0.0/8',
  '172.16.0.0/12',
  'fe80::/10',
]

pass_searxng_org = false
"""
        if let newData = fixed.data(using: .utf8),
           await proxy.writeFileAsync(data: newData, toPath: tomlPath) {
            logs.append("✅ Fixed limiter.toml schema (moved ipv4_prefix/ipv6_prefix to [real_ip]).")
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            logs.append("⚠️ Could not fix limiter.toml (XPC write failed)")
        }
    }

    func migrateBindToLocalhostOnlyIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.bindLocalhostOnlyKey) == nil else { return }
        // Native instance defaults to the more secure localhost-only bind. After the first run this
        // key is persisted and the migration never re-runs.
        UserDefaults.standard.set(true, forKey: Self.bindLocalhostOnlyKey)
    }
}
