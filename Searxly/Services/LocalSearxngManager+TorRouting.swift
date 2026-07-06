//
//  LocalSearxngManager+TorRouting
//  Searxly
//
//  Routes the local SearXNG's UPSTREAM engine traffic through the bundled Tor client while
//  Maximum Privacy's protection is Tor, so native search keeps working without exposing the
//  real IP. (Previously native search was simply blocked in Tor mode.)
//
//  How: SearXNG's `outgoing.proxies` is patched to `socks5h://127.0.0.1:19050` — the bundled
//  runtime ships httpx_socks, and socks5h resolves hostnames at the proxy, so DNS never leaks.
//  The block is wrapped in BEGIN/END markers so it can be removed cleanly when the mode drops.
//  PrivacyGate only opens the loopback-search lane after `torSearchRouted` confirms the running
//  process booted with the proxied config — fail-closed throughout. Expect Tor-grade latency and
//  occasional engines refusing Tor exit IPs; that's inherent to searching over Tor.
//

import Foundation

extension LocalSearxngManager {

    static let torRoutingBeginMarker = "  # BEGIN Searxly Tor routing (managed by Searxly)"
    static let torRoutingEndMarker = "  # END Searxly Tor routing"

    /// The managed block inserted directly under `outgoing:` (2-space YAML indent).
    static var torRoutingBlock: String {
        torRoutingBeginMarker + "\n"
            + "  proxies:\n"
            + "    all://:\n"
            + "      - socks5h://\(TorRuntimeConfig.socksHost):\(TorRuntimeConfig.socksPort)\n"
            + torRoutingEndMarker + "\n"
    }

    /// Whether the current privacy mode wants SearXNG's upstream traffic routed through Tor.
    private var torRoutingDesired: Bool {
        PrivacyManager.shared.appPrivacyMode == .maximum
            && PrivacyManager.shared.maxProtection == .tor
    }

    /// File-only reconcile, run inside `ensureSearxngConfigured()` before every launch, so a booting
    /// process always starts with routing that matches the privacy mode. The full reconcile (with
    /// restart + verification) is `reconcileTorSearchRouting()`.
    func ensureTorOutgoingProxyMatchesPrivacyMode() async {
        _ = await setTorOutgoingProxy(enabled: torRoutingDesired)
    }

    /// Reconciles settings.yml AND the running process with the current privacy mode, then updates
    /// `torSearchRouted` and the PrivacyGate. Restarts SearXNG only when the on-disk config actually
    /// changed (a running process would still be using the old routing). Idempotent; callers may
    /// overlap — reconciles are coalesced and a late runner just re-verifies the settled state.
    func reconcileTorSearchRouting() async {
        if let running = torRoutingReconcileTask { await running.value }
        let task = Task { @MainActor in await performReconcileTorSearchRouting() }
        torRoutingReconcileTask = task
        await task.value
        torRoutingReconcileTask = nil
    }

    private func performReconcileTorSearchRouting() async {
        let desired = torRoutingDesired

        if !desired {
            // Close the search lane immediately — the gate must never sit open on a stale flag.
            torSearchRouted = false
            PrivacyGate.shared.refresh()

            let patch = await setTorOutgoingProxy(enabled: false)
            if patch.succeeded, patch.changed, await isSearxngProcessRunning() {
                logs.append("🧅 Tor routing off — restarting SearXNG with direct engine connections…")
                await restart()
            }
            return
        }

        let patch = await setTorOutgoingProxy(enabled: true)
        guard patch.succeeded else {
            torSearchRouted = false
            PrivacyGate.shared.refresh()
            logs.append("⚠️ Could not route local search through Tor (settings.yml patch failed) — search stays blocked to protect your IP.")
            return
        }

        if patch.changed, await isSearxngProcessRunning() {
            // The running process booted with the direct config — restart onto the Tor-proxied one.
            logs.append("🧅 Maximum Privacy (Tor): restarting SearXNG so engine traffic exits through Tor (socks5h://\(TorRuntimeConfig.socksHost):\(TorRuntimeConfig.socksPort))…")
            await restart()
        } else {
            // Config already correct on disk; every launch path patches before boot
            // (ensureSearxngConfigured), so an already-running process is already proxied.
            await ensureReadyAndRunning()
        }

        torSearchRouted = await isLocalWebReady()
        if torSearchRouted {
            logs.append("✅ Local search now exits through Tor — searches work, expect Tor-grade latency.")
        } else {
            logs.append("⚠️ SearXNG isn't serving after the Tor-routing switch — search stays blocked until it comes up.")
        }
        PrivacyGate.shared.refresh()
    }

    /// Adds/removes the managed `outgoing.proxies` block. File-only — callers decide whether the
    /// running process needs a restart (`changed` says whether the file was rewritten). Idempotent.
    func setTorOutgoingProxy(enabled: Bool) async -> (succeeded: Bool, changed: Bool) {
        guard let proxy = HelperClient.shared.proxy() else { return (false, false) }
        let settingsPath = projectFolderURL.appendingPathComponent("searxng/settings.yml").path
        guard await proxy.fileExistsAsync(atPath: settingsPath),
              let data = await proxy.readFileAsync(atPath: settingsPath),
              var content = String(data: data, encoding: .utf8) else {
            // No settings.yml yet (not provisioned): nothing to patch. Removing is trivially done;
            // enabling can't succeed until the file exists.
            return (!enabled, false)
        }

        let hasBlock = content.contains(Self.torRoutingBeginMarker)

        if enabled {
            if hasBlock { return (true, false) }
            if let outgoingRange = content.range(of: "\noutgoing:\n") {
                content.insert(contentsOf: Self.torRoutingBlock, at: outgoingRange.upperBound)
            } else {
                content += "\n\noutgoing:\n" + Self.torRoutingBlock
            }
        } else {
            guard hasBlock,
                  let begin = content.range(of: Self.torRoutingBeginMarker),
                  let end = content.range(of: Self.torRoutingEndMarker + "\n", range: begin.upperBound..<content.endIndex)
                    ?? content.range(of: Self.torRoutingEndMarker, range: begin.upperBound..<content.endIndex)
            else { return (true, false) }
            content.removeSubrange(begin.lowerBound..<end.upperBound)
        }

        guard let newData = content.data(using: .utf8) else { return (false, false) }
        let ok = await proxy.writeFileAsync(data: newData, toPath: settingsPath)
        if !ok {
            logs.append("⚠️ Could not update SearXNG Tor routing in settings.yml (XPC write failed)")
        }
        return (ok, ok)
    }
}
