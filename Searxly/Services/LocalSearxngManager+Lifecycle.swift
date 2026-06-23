//
//  LocalSearxngManager+Lifecycle
//  Searxly
//

import Foundation
import SwiftUI
import Observation
import Security

extension LocalSearxngManager {
    // MARK: - Public API

    func start() async {
        guard !isBusy else { return }

        // Make sure the project folder + configs exist (real secret etc.). Provision if missing.
        await updateProjectFolderExists()
        if !projectFolderExists {
            do {
                _ = try await provisionIfNeeded()
            } catch {
                lastError = "Failed to prepare local SearXNG folder: \(error.localizedDescription)"
                status = .error(lastError!)
                logs.append("❌ " + (lastError ?? ""))
                return
            }
        }

        if await isLocalWebReady() {
            status = .running
            lastError = nil
            return
        }

        // Process already up but HTTP not ready yet — poll only, never relaunch.
        if await isSearxngProcessRunning() {
            isBusy = true
            status = .starting
            lastError = nil
            logs.append("⏳ SearXNG is already running — waiting for the web server...")
            let ready = await waitForLocalWebReady(maxAttempts: 30, delaySeconds: 2, logProgress: true)
            isBusy = false
            if ready {
                status = .running
                lastError = nil
            } else {
                await refreshStatus()
            }
            return
        }

        // For users who set up before the lean-engine optimization (very common), slim the engine
        // list and ensure the settings.yml bind/port/plugins/limiter are compatible before launch.
        // Safe: only touches the config, backs up the file, runs at most once.
        await ensureFastEngineConfigIfNeeded()
        await ensureMediaEnginesMigratedIfNeeded()
        await ensureSearxngConfigured()

        guard let pythonPath = bundledRuntimePythonPath else {
            lastError = "Bundled SearXNG runtime is missing from the app (Resources/searxng-runtime). Reinstall Searxly."
            status = .error(lastError!)
            logs.append("❌ " + (lastError ?? ""))
            return
        }

        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        let bindAddress = bindToLocalhostOnly ? "127.0.0.1" : "0.0.0.0"

        isBusy = true
        lastError = nil
        status = .starting
        logs.append("▶️ Starting SearXNG (native — no Docker)...")
        logs.append("   bindAddress = \(bindAddress):8080")

        let (pid, errMsg): (Int32, String) = await {
            guard let proxy = DockerHelperClient.shared.proxy() else { return (-1, "Helper service unavailable.") }
            return await proxy.startSearxngAsync(
                pythonExecutablePath: pythonPath,
                settingsPath: settingsPath,
                bindAddress: bindAddress,
                port: 8080
            )
        }()

        if pid <= 0 {
            isBusy = false
            lastError = errMsg.isEmpty ? "Failed to start SearXNG." : errMsg
            status = .error(lastError!)
            logs.append("❌ " + (lastError ?? ""))
            return
        }

        logs.append("   SearXNG launched (pid \(pid)). Waiting for it to become ready (first boot can take 10-30s)...")
        let ready = await waitForLocalWebReady(maxAttempts: 45, delaySeconds: 2, logProgress: true)
        isBusy = false

        if ready {
            status = .running
            lastError = nil
        } else {
            logs.append("⚠️ SearXNG started but the web server is not responding yet.")
            logs.append("   Check the log at ~/searxng-local/searxng.log, or use 'Recreate folder (fresh)' to rebuild a clean config + secret.")
            await refreshStatus()
        }
    }

    func stop() async {
        guard !isBusy else { return }

        isBusy = true
        lastError = nil
        status = .stopping
        logs.append("⏹ Stopping SearXNG...")

        let stopped = await DockerHelperClient.shared.proxy()?.stopSearxngAsync() ?? false
        if !stopped {
            logs.append("⚠️ Could not confirm SearXNG fully stopped (helper unavailable or process unresponsive).")
        }

        isBusy = false
        await refreshStatus()
    }

    func restart() async {
        await stop()
        await start()
    }

    func refreshStatus() async {
        await updateProjectFolderExists()

        // Prefer a live HTTP probe — the definitive signal that SearXNG is serving.
        if await isLocalWebReady() {
            status = .running
            if lastError?.contains("not ready") == true || lastError?.contains("starting") == true {
                lastError = nil
            }
            return
        }

        // Process is up but the web server hasn't finished booting yet.
        if await isSearxngProcessRunning() {
            status = .starting
            lastError = "SearXNG is still starting up. Wait a few seconds and tap refresh (or the status badge)."
        } else {
            status = .stopped
            lastError = nil
        }
    }

    func clearLogs() {
        logs.removeAll()
    }


    // MARK: - Launch warm-up

    /// Schedules a single coalesced launch warm-up. Only runs after onboarding is complete.
    func scheduleLaunchWarmUp() {
        guard mayAutoStartLocalContainer else { return }
        if launchWarmUpTask != nil { return }
        launchWarmUpTask = Task { @MainActor in
            await warmUpLocalSearchOnLaunchIfNeeded()
            launchWarmUpTask = nil
        }
    }

    /// Probe-first launch path: never re-runs compose against a healthy or booting container,
    /// never launches/restarts Docker Desktop, and only starts SearXNG when the daemon is up
    /// and the container is genuinely stopped.
    func warmUpLocalSearchOnLaunchIfNeeded() async {
        guard mayAutoStartLocalContainer else { return }

        await updateProjectFolderExists()
        await refreshStatus()

        if await isLocalWebReady() {
            status = .running
            lastError = nil
            return
        }

        if await isSearxngProcessRunning() {
            status = .starting
            lastError = nil
            if await waitForLocalWebReady(maxAttempts: 45, delaySeconds: 2) {
                status = .running
                lastError = nil
            } else {
                await refreshStatus()
            }
            return
        }

        guard projectFolderExists else { return }
        guard !isBusy else { return }

        await start()
    }

    // MARK: - High-level automatic provisioning APIs (for "almost nothing to do" onboarding)

    /// The main "make it just work" API for the automatic onboarding path.
    /// Ensures the folder+configs exist (real secret injected), launches the bundled native SearXNG
    /// process if necessary, and waits for the web server to be responsive. No Docker, no downloads —
    /// the runtime ships inside the app. Updates status, logs, and lastError for the UI to observe.
    func ensureReadyAndRunning() async {
        if let warmUp = launchWarmUpTask {
            await warmUp.value
        }

        if let existing = ensureReadyTask {
            await existing.value
            return
        }

        let task = Task { @MainActor in
            await performEnsureReadyAndRunning()
        }
        ensureReadyTask = task
        await task.value
        ensureReadyTask = nil
    }

    private func performEnsureReadyAndRunning() async {
        // Already serving — nothing to do.
        if await isLocalWebReady() {
            status = .running
            lastError = nil
            return
        }

        // Another start/warm-up is in progress — wait for it, then re-check readiness.
        if isBusy {
            await currentTask?.value
            if await isLocalWebReady() {
                status = .running
                lastError = nil
            } else {
                await refreshStatus()
            }
            return
        }

        // Process is up but the web server is still booting — wait, do not relaunch.
        if await isSearxngProcessRunning() {
            status = .starting
            lastError = nil
            if await waitForLocalWebReady(maxAttempts: 30, delaySeconds: 2) {
                status = .running
                lastError = nil
                return
            }
            await refreshStatus()
            return
        }

        // Make sure we have the files (real secret etc.). Safe if already present.
        do {
            _ = try await provisionIfNeeded()
        } catch {
            lastError = "Failed to prepare local SearXNG folder: \(error.localizedDescription)"
            logs.append("❌ " + (lastError ?? ""))
            status = .error(lastError!)
            return
        }

        // Apply config optimizations: lean engines, media migration, and bind/port/plugins/limiter.
        await ensureFastEngineConfigIfNeeded()
        await ensureMediaEnginesMigratedIfNeeded()
        await ensureSearxngConfigured()

        // Launch (start() short-circuits if already serving).
        await start()
    }

    /// Polls the local SearXNG HTTP endpoint until it responds or attempts are exhausted.
    func waitForLocalWebReady(
        maxAttempts: Int = 30,
        delaySeconds: UInt64 = 2,
        logProgress: Bool = false
    ) async -> Bool {
        for attempt in 0..<maxAttempts {
            if await isLocalWebReady() {
                return true
            }
            if logProgress, attempt % 5 == 4 {
                logs.append("⏳ Still waiting for web server (attempt \(attempt + 1)/\(maxAttempts))...")
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
        }
        return false
    }

    /// Updates `projectFolderExists` via the XPC helper (required under App Sandbox).
    func updateProjectFolderExists() async {
        guard let proxy = DockerHelperClient.shared.proxy() else {
            projectFolderExists = false
            return
        }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        projectFolderExists = await proxy.fileExistsAsync(atPath: settingsPath)
    }

    /// One-time (or on-demand) optimization for existing installs.
    /// The full upstream settings.yml.example has 100+ engines. Even disabled ones make
    /// SearXNG's Python startup much slower and use more memory — especially painful on
    /// 8GB/16GB Macs where Docker Desktop's VM is already memory-starved.
    ///
    /// This safely detects the bloated default and replaces only the engines: section
    /// with our lean fast set (same list we use for brand-new setups). A backup is kept.
    ///
    /// IMPORTANT: The injected list must stay compatible with the engines shipped in
    /// the current `searxng/searxng:latest` image (see creation path for details).
    /// We also force-reapply on any polluted file that still contains ahmia/bandcamp
    /// dupes / stackoverflow / arxiv (even if the DidApplyLean key is already true)
    /// so that users hitting CrashLoop from prior bad writes get automatically fixed.
    func ensureFastEngineConfigIfNeeded() async {
        guard let proxy = DockerHelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath) else { return }

        let didOptimizeKey = "Searxly.DidApplyLeanSearxngEngines"

        guard let data = await proxy.readFileAsync(atPath: settingsPath),
              let content = String(data: data, encoding: .utf8) else { return }

        // Robustness for users who previously hit a bad lean write (the cut bug that left
        // ahmia + duplicate bandcamp + arxiv/stackoverflow tail in settings.yml, causing
        // exactly the CrashLoop + "waiting for web server 30 times" the user reported).
        // Even if the DidApplyLean key is true (from the prior bad run), force a re-apply
        // + backup if any known crashing engines are still present.
        // `engine: artstation` is not shipped in the pinned image (FileNotFoundError on every boot);
        // `engine: flickr` (the API variant) needs a flickr.api_key we don't provide — the keyless
        // `flickr_noapi` is the correct engine. Both crash-loop SearXNG workers on cold start, so
        // detecting them here force-reapplies the corrected lean list to already-provisioned folders.
        let hasProblematicEngines = content.contains("  - name: ahmia") ||
                                    content.contains("  - name: stackoverflow") ||
                                    content.contains("  - name: arxiv") ||
                                    content.contains("engine: artstation") ||
                                    content.contains("engine: flickr\n") ||
                                    (content.components(separatedBy: "  - name: bandcamp").count > 2)

        if UserDefaults.standard.bool(forKey: didOptimizeKey) && !hasProblematicEngines {
            return
        }

        // Heuristic: bloated if it still contains several engines we know are in the old full example
        // and we have many engine definitions. (Also catches polluted files from the old cutter.)
        let bloatedSignals = ["360search", "adobe stock", "chinaso", "annas archive", "btdigg", "kickass"]
        let hasBloatedSignal = bloatedSignals.contains { content.contains($0) }
        let engineCount = content.components(separatedBy: "  - name:").count - 1

        guard hasBloatedSignal || engineCount > 25 || hasProblematicEngines else {
            // Looks like user already has a custom/lean list — don't touch it.
            UserDefaults.standard.set(true, forKey: didOptimizeKey)
            return
        }

        // Backup once (or again for polluted recovery) — read current content then write to backup path
        let backupPath = settingsPath + ".bak-pre-lean"
        let backupExists = await proxy.fileExistsAsync(atPath: backupPath)
        if !backupExists {
            if let backupData = await proxy.readFileAsync(atPath: settingsPath) {
                _ = await proxy.writeFileAsync(data: backupData, toPath: backupPath)
                logs.append("📦 Backed up your old settings.yml to settings.yml.bak-pre-lean before applying lean config.")
            }
        }

        // Use the same fast block we use for new folders
        // NOTE: This list must only contain engines that exist in the current
        // searxng/searxng:latest image. 'stackoverflow', 'arxiv', 'ahmia', and
        // 'bandcamp' (duplicate/ambiguous name or load failures) have been observed
        // to be missing or misconfigured in recent images, causing Python import
        // crashes, worker exits, and continuous restart loops. Keep the list minimal
        // for fast, reliable startup.
        let fastEnginesBlock = LeanSearxngEngines.block

        // Replace engines: section (same logic as the new-install path)
        if let enginesStart = content.range(of: "\nengines:") ?? content.range(of: "engines:") {
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

            // NOTE: The previous "\n\n last resort" splitter has been removed (see creation
            // path for full rationale). Engines: is the last section; we replace to EOF.
            // This + the hasProblematicEngines guard above ensures even previously-polluted
            // ~/searxng-local/searxng/settings.yml (the cause of the user's docker CrashLoop
            // with ahmia + bandcamp duplicate) gets a clean lean list on next Start or
            // auto "Download & start" button press.
            // We now preserve any tail after engines (e.g. doi_resolvers from original) and
            // guarantee default_doi_resolver is present to avoid KeyError in SearXNG startup.

            let before = content[..<enginesStart.lowerBound]
            let tail = content[cutPoint...]
            var newContent = before + "\n" + fastEnginesBlock
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newContent += "\n" + tail
            }
            if !newContent.contains("default_doi_resolver:") {
                newContent += """

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

            if let newData = newContent.data(using: .utf8),
               await proxy.writeFileAsync(data: newData, toPath: settingsPath) {
                logs.append("✅ Lean/fast engine list applied cleanly to existing SearXNG config (only stable engines; any prior ahmia/bandcamp dupes or old tail removed by the fixed cutter + hasProblematic guard). doi_resolvers section ensured present to fix KeyError on startup.")
                logs.append("   Big startup speed win + no more engine crash loops on low-RAM Macs. The container will use the clean config on its next (re)start.")
                logs.append("   If it's currently running you may want to Stop → Start again (or just tap the main Download & start button).")
                UserDefaults.standard.set(true, forKey: didOptimizeKey)
            } else {
                logs.append("⚠️ Failed to optimize SearXNG config for speed (XPC write failed)")
            }
        }
    }

    /// Appends missing media engines to existing lean Searxly configs without wiping customizations.
    func ensureMediaEnginesMigratedIfNeeded() async {
        let migrationKey = "Searxly.DidMigrateMediaEngines2026"
        guard let proxy = DockerHelperClient.shared.proxy() else { return }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              var content = String(data: data, encoding: .utf8) else { return }

        // Only migrate lean Searxly-managed lists (has bing images).
        guard content.contains("  - name: bing images") else { return }

        var appendedAny = false
        for entry in LeanSearxngEngines.mediaMigrationEntries where !content.contains(entry.marker) {
            if let insertPoint = content.range(of: "\ndoi_resolvers:") ?? content.range(of: "\n# DOI resolvers") {
                content.insert(contentsOf: "\n" + entry.yaml, at: insertPoint.lowerBound)
            } else if let githubRange = content.range(of: "  - name: github") {
                content.insert(contentsOf: "\n" + entry.yaml, at: githubRange.lowerBound)
            } else {
                content.append("\n" + entry.yaml)
            }
            appendedAny = true
        }

        guard appendedAny else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        if let newData = content.data(using: .utf8),
           await proxy.writeFileAsync(data: newData, toPath: settingsPath) {
            logs.append("✅ Media engines migration applied (flickr, deviantart, artstation, dailymotion, vimeo). Restart SearXNG to pick up changes.")
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            logs.append("⚠️ Failed to migrate media engines (XPC write failed)")
        }
    }

}
