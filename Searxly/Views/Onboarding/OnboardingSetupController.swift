//
//  OnboardingSetupController.swift
//  Searxly
//

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingSetupController {
    var newInstanceName = "Local SearXNG"
    var newInstanceURL = LocalSearxngManager.shared.defaultLocalInstanceURL
    var isTestingConnection = false
    var connectionStatus: String?
    var isConnectionSuccessful = false
    var hasTriggeredAutoSetup = false

    let localSearxng = LocalSearxngManager.shared

    private var connectionTestTask: Task<Void, Never>?
    private var setupProbeTask: Task<Void, Never>?

    func cancelAllTasks() {
        connectionTestTask?.cancel()
        setupProbeTask?.cancel()
        isTestingConnection = false
    }

    func resetForStepEntry() {
        hasTriggeredAutoSetup = false
        cancelAllTasks()
    }

    func scheduleSetupProbe(activeStep: Int, existingInstanceURLs: [String]) {
        setupProbeTask?.cancel()
        setupProbeTask = Task { @MainActor in
            await prepareSetupStep(activeStep: activeStep, existingInstanceURLs: existingInstanceURLs)
        }
    }

    /// Passive status refresh on step entry: never starts Docker, never marks success without user action.
    func prepareSetupStep(activeStep: Int, existingInstanceURLs: [String]) async {
        guard activeStep == 1, !isConnectionSuccessful else { return }
        guard !Task.isCancelled else { return }

        newInstanceName = "Local SearXNG"
        newInstanceURL = localSearxng.defaultLocalInstanceURL

        // No Docker CLI / HTTP probes here — nothing touches Docker until the user taps a button.
        connectionStatus = idleStatusMessage()

        hasTriggeredAutoSetup = true
        isTestingConnection = false
    }

    func probeExistingConfiguredInstance(existingInstanceURLs: [String], updatesUI: Bool = true) async -> Bool {
        let candidates = existingInstanceURLs + [localSearxng.defaultLocalInstanceURL]
        var seen = Set<String>()

        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            guard trimmed.contains("localhost") || trimmed.contains("127.0.0.1") else { continue }

            newInstanceURL = trimmed
            newInstanceName = "Local SearXNG"
            if await runConnectionProbe(maxAttempts: 3, delaySeconds: 1, updatesUI: updatesUI) {
                connectionStatus = "Connected — local SearXNG ready at \(trimmed)."
                return true
            }
        }
        return false
    }

    func useLocalAndTest(quick: Bool = false) {
        connectionTestTask?.cancel()
        newInstanceName = "Local SearXNG"
        newInstanceURL = localSearxng.defaultLocalInstanceURL
        if !quick {
            connectionStatus = nil
            isConnectionSuccessful = false
        }
        testConnection(quick: quick)
    }

    func testConnection(quick: Bool = false) {
        connectionTestTask?.cancel()

        let trimmedURL = newInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmedURL) != nil else {
            connectionStatus = "Enter a valid URL."
            isConnectionSuccessful = false
            isTestingConnection = false
            return
        }

        if SearXNGInstance.isPublicInstance(url: trimmedURL) {
            connectionStatus = "Public instances are not supported."
            isConnectionSuccessful = false
            isTestingConnection = false
            return
        }

        isTestingConnection = true
        connectionStatus = "Testing connection…"

        let isLocal = trimmedURL.contains("localhost") || trimmedURL.contains("127.0.0.1")
        let maxAttempts = quick ? 3 : (isLocal ? 30 : 1)

        connectionTestTask = Task { @MainActor in
            let success = await runConnectionProbe(maxAttempts: maxAttempts, delaySeconds: quick ? 1 : 3, updatesUI: true)
            guard !Task.isCancelled else { return }
            isTestingConnection = false
            if !success,
               connectionStatus == "Testing connection…"
                || connectionStatus?.hasPrefix("Waiting for SearXNG") == true
                || connectionStatus?.contains("Starting private SearXNG") == true {
                connectionStatus = isLocal
                    ? "Could not reach local SearXNG. Tap Start local search again, or Rebuild fresh under Troubleshooting."
                    : "Connection failed."
                isConnectionSuccessful = false
            }
        }
    }

    /// User-initiated: provision + start container + wait for readiness.
    func startLocalSearch() async {
        localSearxng.clearLogs()
        newInstanceName = "Local SearXNG"
        newInstanceURL = localSearxng.defaultLocalInstanceURL
        isTestingConnection = true
        connectionStatus = "Preparing local SearXNG…"

        defer { isTestingConnection = false }

        if await markSuccessIfLocalReady() { return }

        await localSearxng.ensureReadyAndRunning()
        guard !Task.isCancelled else { return }

        if await markSuccessIfLocalReady() { return }

        connectionStatus = "Waiting for SearXNG to respond…"
        let success = await runConnectionProbe(maxAttempts: 30, delaySeconds: 2, updatesUI: true)
        if success { return }

        if !isConnectionSuccessful {
            connectionStatus = "Could not reach local SearXNG. Check Troubleshooting below, or tap Rebuild fresh."
        }
    }

    @discardableResult
    func markSuccessIfLocalReady() async -> Bool {
        if await localSearxng.isLocalWebReady() {
            applySuccessState()
            return true
        }

        if localSearxng.status == .running {
            applySuccessState()
            return true
        }

        return false
    }

    func applySuccessState() {
        let url = localSearxng.defaultLocalInstanceURL
        newInstanceURL = url
        connectionStatus = "Connected — local SearXNG ready at \(url)."
        isConnectionSuccessful = true
        isTestingConnection = false
    }

    func idleStatusMessage() -> String {
        let mgr = localSearxng
        if case .starting = mgr.status {
            return "SearXNG is starting. Tap Start local search to finish setup, or wait a moment and tap Test connection."
        }
        if case .error(let msg) = mgr.status {
            return "Setup issue: \(msg). Tap Start local search to retry."
        }
        return "Tap Start local search to create and launch your private SearXNG on this Mac."
    }

    @discardableResult
    func runConnectionProbe(maxAttempts: Int, delaySeconds: UInt64, updatesUI: Bool) async -> Bool {
        if updatesUI {
            isTestingConnection = true
        }

        defer {
            if updatesUI {
                isTestingConnection = false
            }
        }

        let trimmedURL = newInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL) else { return false }

        if await markSuccessIfLocalReady() {
            return true
        }

        let isLocal = trimmedURL.contains("localhost") || trimmedURL.contains("127.0.0.1")
        let probeURLs: [URL] = {
            if isLocal {
                return localSearxng.localWebProbeURLs.compactMap { URL(string: $0) }
            }
            return [url]
        }()

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return false }

            for probeURL in probeURLs {
                guard !Task.isCancelled else { return false }
                if await fetchSearxngProbe(probeURL) {
                    newInstanceURL = probeURL.absoluteString
                    connectionStatus = isLocal
                        ? "Connected — local SearXNG ready at \(probeURL.absoluteString)."
                        : "Connected."
                    isConnectionSuccessful = true
                    return true
                }
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return false }
                if updatesUI {
                    connectionStatus = (isLocal && maxAttempts > 5)
                        ? "Starting private SearXNG… (first boot can take 30–90s)"
                        : "Waiting for SearXNG… (\(attempt)/\(maxAttempts))"
                }
            }
        }
        return false
    }

    func fetchSearxngProbe(_ probeURL: URL) async -> Bool {
        let host = probeURL.host?.lowercased() ?? ""
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"

        var effectiveURL = probeURL
        let path = probeURL.path
        if path.isEmpty || path == "/" {
            if let withSlash = URL(string: probeURL.absoluteString.hasSuffix("/") ? probeURL.absoluteString : probeURL.absoluteString + "/") {
                effectiveURL = withSlash
            }
        }

        do {
            var req = URLRequest(url: effectiveURL)
            req.timeoutInterval = 8
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                let code = http.statusCode
                let acceptableForLocal = (200...399).contains(code) || (400...599).contains(code)
                if isLocal && acceptableForLocal {
                    return true
                }
                if (200...299).contains(code) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    if body.lowercased().contains("searxng") || body.lowercased().contains("searxly") || body.lowercased().contains("searx") {
                        return true
                    }
                    if isLocal, body.contains("<") {
                        return true
                    }
                    if !isLocal {
                        connectionStatus = "Not a SearXNG instance."
                        isConnectionSuccessful = false
                    }
                }
            }
        } catch {
            return false
        }
        return false
    }

    func applyInstance(
        searxInstances: inout [SearXNGInstance],
        currentInstanceID: inout UUID
    ) {
        guard isConnectionSuccessful else { return }

        let name = newInstanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "Local SearXNG" : name
        let trimmedURL = newInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedURL.isEmpty else { return }

        if SearXNGInstance.isPublicInstance(url: trimmedURL) {
            connectionStatus = "Public instances are not supported."
            isConnectionSuccessful = false
            return
        }

        if let existingIndex = searxInstances.firstIndex(where: { $0.url == trimmedURL }) {
            if !finalName.isEmpty {
                searxInstances[existingIndex].name = finalName
            }
            currentInstanceID = searxInstances[existingIndex].id
            return
        }

        let inst = SearXNGInstance(name: finalName, url: trimmedURL)
        searxInstances.append(inst)
        currentInstanceID = inst.id
    }
}