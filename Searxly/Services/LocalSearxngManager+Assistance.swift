//
//  LocalSearxngManager+Assistance
//  Searxly
//

import Foundation
import SwiftUI
import Observation
import Security

extension LocalSearxngManager {
    // MARK: - Folder helpers

    /// Opens the ~/searxng-local folder in Finder for advanced users / debugging.
    func openProjectFolderInFinder() {
        NSWorkspace.shared.open(projectFolderURL)
    }

    /// Deletes the local project folder and recreates it fresh (useful for corrupted setups or testing).
    /// Does NOT start SearXNG.
    func recreateProjectFolder() async {
        do {
            guard let proxy = HelperClient.shared.proxy() else {
                logs.append("❌ XPC helper unavailable — cannot remove ~/searxng-local")
                return
            }
            if await proxy.fileExistsAsync(atPath: projectFolderURL.path) {
                _ = await proxy.removeItemAsync(atPath: projectFolderURL.path)
                logs.append("🗑️ Removed existing ~/searxng-local")
            }
            _ = try await ensureProjectFolderExists()
            logs.append("✅ Fresh local SearXNG setup folder created. Tap Start or 'Set up & start automatically'.")
            await updateProjectFolderExists()
        } catch {
            lastError = "Failed to recreate folder: \(error.localizedDescription)"
            logs.append("❌ " + (lastError ?? ""))
        }
    }

    /// Returns a copy of recent logs (for diagnostics / "Copy logs" buttons in UI).
    func recentLogs() -> [String] {
        return logs
    }

    /// Copies recent logs to the pasteboard (convenience for users reporting issues).
    func copyRecentLogsToPasteboard() {
        let text = logs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logs.append("📋 Logs copied to clipboard")
    }
}
