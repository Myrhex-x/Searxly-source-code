//
//  LocalSearxngManager+Provisioning
//  Searxly
//

import Foundation
import SwiftUI
import Observation
import Security

extension LocalSearxngManager {
    // MARK: - Secret generation (runtime, never committed)

    func generateSecureSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - One-click Project Folder Creation (used by Onboarding + Settings)

    /// Creates (or repairs) the ~/searxng-local folder with the required searxng/ config files
    /// (settings.yml + limiter.toml + theme) copied from the app bundle. All file I/O is routed
    /// through the XPC helper so this is safe under App Sandbox.
    @discardableResult
    func ensureProjectFolderExists() async throws -> URL {
        lastError = nil

        guard let proxy = HelperClient.shared.proxy() else {
            throw NSError(
                domain: "Searxly.LocalSearxng",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "XPC helper unavailable — cannot access ~/searxng-local"]
            )
        }

        let fm = FileManager.default
        let targetRoot = projectFolderURL
        let configDir = targetRoot.appendingPathComponent("searxng")

        // Reads a bundled resource (bundle access is allowed under App Sandbox) and
        // writes it to a destination path via the XPC helper (required under App Sandbox).
        func copyBundledFile(resource: String, ext: String, destination: URL) async throws {
            var candidates: [URL?] = [
                Bundle.main.url(forResource: resource, withExtension: ext),
                Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "LocalSearxng"),
                Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "LocalSearxng/searxng"),
            ]

            if resource == "settings" && ext == "yml" {
                candidates.append(contentsOf: [
                    Bundle.main.url(forResource: "settings", withExtension: "yml.example"),
                    Bundle.main.url(forResource: "settings", withExtension: "yml.example", subdirectory: "LocalSearxng"),
                    Bundle.main.url(forResource: "settings", withExtension: "yml.example", subdirectory: "LocalSearxng/searxng"),
                ])
            }

            guard let source = candidates.compactMap({ $0 }).first else {
                throw NSError(
                    domain: "Searxly.LocalSearxng",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing bundled resource: \(resource).\(ext). Make sure the LocalSearxng/ folder reference is added to the app target in Xcode."]
                )
            }

            guard let data = try? Data(contentsOf: source) else {
                throw NSError(
                    domain: "Searxly.LocalSearxng",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not read bundled resource: \(source.lastPathComponent)"]
                )
            }

            _ = await proxy.removeItemAsync(atPath: destination.path)
            let ok = await proxy.writeFileAsync(data: data, toPath: destination.path)
            if !ok {
                throw NSError(
                    domain: "Searxly.LocalSearxng",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "XPC: failed to write \(destination.lastPathComponent) to ~/searxng-local"]
                )
            }
        }

        // Copies a bundled directory tree to a destination via XPC.
        // Enumerates the source in the bundle (allowed under App Sandbox) and
        // writes each regular file through the XPC helper.
        func copyBundledDirectory(dirName: String, destination: URL) async throws {
            let candidates: [URL?] = [
                Bundle.main.resourceURL?.appendingPathComponent(dirName),
                Bundle.main.resourceURL?.appendingPathComponent("LocalSearxng").appendingPathComponent(dirName),
                Bundle.main.resourceURL?.appendingPathComponent("LocalSearxng/custom").appendingPathComponent(dirName),
            ]
            let resourceCandidates: [URL?] = [
                Bundle.main.url(forResource: dirName, withExtension: nil),
                Bundle.main.url(forResource: dirName, withExtension: nil, subdirectory: "LocalSearxng"),
            ]

            if let source = (candidates + resourceCandidates)
                .compactMap({ $0 })
                .first(where: { fm.fileExists(atPath: $0.path) }) {

                _ = await proxy.removeItemAsync(atPath: destination.path)

                if let enumerator = fm.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                        else { continue }

                        let relPath = String(fileURL.path.dropFirst(source.path.count))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let destPath = destination.appendingPathComponent(relPath).path

                        guard let data = try? Data(contentsOf: fileURL) else { continue }
                        _ = await proxy.writeFileAsync(data: data, toPath: destPath)
                    }
                }
                return
            }

            // Bulletproof fallback for flattened bundle (common with synchronized groups).
            logs.append("ℹ️ custom/ directory not found in bundle (flattened resources). Reconstructing from flat theme files...")

            let themeFiles: [(name: String, relativeDest: String)] = [
                ("base.html",       "templates/simple/base.html"),
                ("categories.html", "templates/simple/categories.html"),
                ("index.html",      "templates/simple/index.html"),
                ("results.html",    "templates/simple/results.html"),
                ("search.html",     "templates/simple/search.html"),
                ("default.html",    "templates/simple/result_templates/default.html"),
                ("searxly.css",     "static/themes/simple/searxly.css"),
            ]

            var deployedAny = false
            for (fileName, relDest) in themeFiles {
                var fileURL: URL?
                if let url = Bundle.main.url(forResource: fileName, withExtension: nil) {
                    fileURL = url
                } else if let url = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "LocalSearxng") {
                    fileURL = url
                }

                guard let source = fileURL, fm.fileExists(atPath: source.path) else { continue }
                guard let data = try? Data(contentsOf: source) else { continue }

                let destPath = destination.appendingPathComponent(relDest).path
                _ = await proxy.writeFileAsync(data: data, toPath: destPath)
                deployedAny = true
            }

            if deployedAny {
                logs.append("✅ Premium Searxly theme reconstructed at \(destination.path)")
            } else {
                logs.append("⚠️ Could not locate any theme files for custom/ deployment. Searches may use default SearXNG styling.")
            }
        }

        // Idempotency / safety for existing users:
        // If settings.yml already exists, only refresh ancillary files (limiter.toml + theme).
        // Do not overwrite settings.yml which may contain user customizations.
        let settingsURL = configDir.appendingPathComponent("settings.yml")
        if await proxy.fileExistsAsync(atPath: settingsURL.path) {
            try? await copyBundledFile(
                resource: "limiter",
                ext: "toml",
                destination: configDir.appendingPathComponent("limiter.toml")
            )
            try? await copyBundledDirectory(
                dirName: "custom",
                destination: targetRoot.appendingPathComponent("custom")
            )
            await patchSettingsYMLForLocalPrivacy()
            await updateProjectFolderExists()
            return targetRoot
        }

        // Fresh install — create directory structure via XPC.
        _ = await proxy.createDirectoryAsync(atPath: targetRoot.path)
        _ = await proxy.createDirectoryAsync(atPath: configDir.path)

        do {
            // NOTE (sanitized source repo): committed template is settings.yml.example (placeholder secret).
            // The copy + post-process below produces a real settings.yml with a generated secret.
            try await copyBundledFile(
                resource: "settings",
                ext: "yml",
                destination: configDir.appendingPathComponent("settings.yml")
            )

            // Inject a real secret and apply speed optimization (lean engines list).
            let settingsDest = configDir.appendingPathComponent("settings.yml")
            if await proxy.fileExistsAsync(atPath: settingsDest.path),
               let rawData = await proxy.readFileAsync(atPath: settingsDest.path),
               var content = String(data: rawData, encoding: .utf8) {

                let secret = generateSecureSecret()

                if let regex = try? NSRegularExpression(pattern: #"secret_key:\s*"[^"]*""#, options: []) {
                    let range = NSRange(content.startIndex..., in: content)
                    content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "secret_key: \"\(secret)\"")
                }

                content = content.replacingOccurrences(of: "SANITIZED TEMPLATE FOR OPEN SOURCE / PUBLIC REPO", with: "Searxly local instance — secret generated automatically on first setup")
                content = content.replacingOccurrences(of: "Replace secret_key with your own strong random value BEFORE first use.", with: "Secret was generated automatically by Searxly (no action needed).")

                content = Self.patchEnableMetricsOff(in: content)

                // === SPEED OPTIMIZATION ===
                // Replace full engines: block with lean curated set. Avoids slow startup on 8/16 GB Macs
                // and eliminates crash loops from engines missing in the pinned image (ahmia, bandcamp, etc.).
                if let enginesStart = content.range(of: "\nengines:") ?? content.range(of: "engines:") {
                    let fastEnginesBlock = LeanSearxngEngines.block

                    var cutPoint = content.endIndex
                    let searchFrom = enginesStart.upperBound
                    let remaining = content[searchFrom...]

                    let markers = ["\nui:", "\noutgoing:", "\nplugins:", "\n# communication", "\nserver:", "\nvalkey:", "\ndoi_resolvers:"]
                    for m in markers {
                        if let r = remaining.range(of: m) {
                            let distance = remaining.distance(from: remaining.startIndex, to: r.lowerBound)
                            let candidate = content.index(searchFrom, offsetBy: distance)
                            if candidate < cutPoint { cutPoint = candidate }
                        }
                    }

                    let before = content[..<enginesStart.lowerBound]
                    let tail = content[cutPoint...]
                    var newSettings = before + "\n" + fastEnginesBlock
                    if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        newSettings += "\n" + tail
                    }
                    if !newSettings.contains("default_doi_resolver:") {
                        newSettings += """

# DOI resolvers (preserved / injected by Searxly — required by SearXNG config loader in recent images)
doi_resolvers:
  oadoi.org: 'https://oadoi.org/'
  doi.org: 'https://doi.org/'
  sci-hub.se: 'https://sci-hub.se/'
  sci-hub.st: 'https://sci-hub.st/'
  sci-hub.ru: 'https://sci-hub.ru/'

default_doi_resolver: 'oadoi.org'
"""
                    }
                    content = newSettings
                }

                if let finalData = content.data(using: .utf8) {
                    _ = await proxy.writeFileAsync(data: finalData, toPath: settingsDest.path)
                    logs.append("✅ Lean/fast engine list written cleanly (fresh creation: only stable image-shipped engines; ahmia, bandcamp, stackoverflow, arxiv and bloated old tail excluded. doi_resolvers + default_doi_resolver are now guaranteed to be present.)")
                }
            }

            try await copyBundledFile(
                resource: "limiter",
                ext: "toml",
                destination: configDir.appendingPathComponent("limiter.toml")
            )

            try await copyBundledDirectory(
                dirName: "custom",
                destination: targetRoot.appendingPathComponent("custom")
            )
        } catch {
            // Best-effort cleanup so we don't leave a half-broken folder.
            _ = await proxy.removeItemAsync(atPath: targetRoot.path)
            throw error
        }

        // For brand-new automatic setups, default to the more secure localhost-only bind.
        bindToLocalhostOnly = true

        // Patch the freshly written settings.yml so the very first launch uses correct bind/port.
        await ensureSearxngConfigured()

        await updateProjectFolderExists()
        logs.append("✅ Project folder created at \(targetRoot.path)")
        return targetRoot
    }

    /// Ensures local-only privacy defaults in the on-disk settings.yml (metrics off).
    /// Safe to call on existing installs — does not touch secret_key or engines.
    func patchSettingsYMLForLocalPrivacy() async {
        guard let proxy = HelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              let content = String(data: data, encoding: .utf8) else { return }

        let patched = Self.patchEnableMetricsOff(in: content)
        guard patched != content, let newData = patched.data(using: .utf8) else { return }

        if await proxy.writeFileAsync(data: newData, toPath: settingsPath) {
            logs.append("✅ Local privacy defaults applied (enable_metrics: false).")
        } else {
            logs.append("⚠️ Could not patch settings.yml for local privacy (XPC write failed)")
        }
    }

    private static func patchEnableMetricsOff(in content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"enable_metrics:\s*(true|false)"#, options: []) else {
            return content
        }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(
            in: content,
            options: [],
            range: range,
            withTemplate: "enable_metrics: false"
        )
    }

    /// Safe entry point for automatic flows. Creates the folder+configs (with real secret) only if needed.
    @discardableResult
    func provisionIfNeeded() async throws -> URL {
        return try await ensureProjectFolderExists()
    }

}
