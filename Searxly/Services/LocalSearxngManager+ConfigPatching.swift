//
//  LocalSearxngManager+ConfigPatching
//  Searxly
//
//  Patches the on-disk SearXNG settings.yml / limiter.toml to stay compatible with the bundled
//  SearXNG and Searxly's local-private defaults. No Docker/compose — the runtime is native.
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
        await ensurePluginsSectionCompatibleIfNeeded()
        await ensureLimiterTomlCompatibleIfNeeded()
    }

    /// Ensures settings.yml has a sane localhost bind + the right port. The helper passes the live
    /// bind address via the SEARXNG_BIND_ADDRESS env var (which overrides settings.yml), so this is
    /// just a safe default; the LAN-exposure toggle is honored at launch through that env var.
    func ensureSettingsYmlBindPort() async {
        guard let proxy = DockerHelperClient.shared.proxy() else { return }
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
        guard let proxy = DockerHelperClient.shared.proxy() else { return }

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
        guard let proxy = DockerHelperClient.shared.proxy() else {
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
