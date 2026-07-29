//
//  ExtensionInstallChip.swift
//  Searxly
//
//  Headless coordinator for the Chrome Web Store install flow. The visible "Add to Searxly" affordance
//  now lives IN the store page itself (an injected popup card — see ChromeWebStore.storeBridgeScript);
//  this host has no UI of its own. Its jobs:
//    • present the NATIVE permission prompt (the trust anchor — a web page can never fake it), and
//    • push flow state back into the in-page popup (installing → installed / error) via the bridge world.
//
//  It's triggered by `.chromeWebStoreInstallClicked`, which the page bridge's native handler posts when
//  the user clicks the in-page (or the store's own) install button. Standard tabs / macOS 15.4+ only.
//

import SwiftUI
import WebKit

struct ExtensionInstallHost: View {
    /// The active tab's webview — used to push install-flow state into the store page's popup.
    let activeWebView: WKWebView
    let currentURL: URL?
    let isStandardTab: Bool

    @State private var pending: PendingStoreInstall?
    @State private var showConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var installing = false

    private var detectedID: String? { ChromeWebStore.detailPageExtensionID(of: currentURL) }

    var body: some View {
        if #available(macOS 15.4, *), ExtensionFeatures.programEnabled, isStandardTab {
            Color.clear
                .frame(width: 0, height: 0)
                .onReceive(NotificationCenter.default.publisher(for: .chromeWebStoreInstallClicked)) { _ in
                    beginInstall()
                }
                .alert(
                    "Add \u{201C}\(pending?.displayName ?? "extension")\u{201D}?",
                    isPresented: $showConfirm,
                    presenting: pending
                ) { p in
                    Button("Add Extension") { confirm(p) }
                    Button("Cancel", role: .cancel) { cancel(p) }
                } message: { p in
                    Text(permissionSummary(p))
                }
                .alert("Couldn't install", isPresented: $showError) {
                    Button("OK") {}
                } message: {
                    Text(errorMessage ?? "Something went wrong.")
                }
        }
    }

    // MARK: - Flow

    private func beginInstall() {
        guard #available(macOS 15.4, *), !installing, let id = detectedID else { return }
        installing = true
        pushState("installing")
        Task {
            do {
                let p = try await ExtensionManager.shared.fetchFromChromeWebStore(id)
                pending = p
                showConfirm = true
            } catch {
                installing = false
                errorMessage = error.localizedDescription
                showError = true
                pushState("error", detail: error.localizedDescription)
            }
        }
    }

    private func confirm(_ p: PendingStoreInstall) {
        guard #available(macOS 15.4, *) else { return }
        Task {
            do {
                _ = try await ExtensionManager.shared.confirmStoreInstall(p)
                pushState("installed")
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                pushState("error", detail: error.localizedDescription)
            }
            pending = nil
            installing = false
        }
    }

    private func cancel(_ p: PendingStoreInstall) {
        if #available(macOS 15.4, *) {
            ExtensionManager.shared.cancelStoreInstall(p)
        }
        pending = nil
        installing = false
        pushState("idle")
    }

    /// Pushes flow state into the store page's popup (bridge content world). No-op off store pages —
    /// the setter simply won't exist there.
    private func pushState(_ state: String, detail: String = "") {
        guard #available(macOS 15.4, *) else { return }
        let world = WKContentWorld.world(name: ChromeWebStore.storeBridgeWorldName)
        let js = ChromeWebStore.popupStateJS(state, detail: detail)
        // Fire-and-forget in the bridge's content world (completion-handler form; the `nil` handler
        // keeps it synchronous — no try/await no-ops).
        activeWebView.evaluateJavaScript(js, in: nil, in: world, completionHandler: nil)
    }

    /// Chrome-style plain-language summary of what the user is agreeing to.
    private func permissionSummary(_ p: PendingStoreInstall) -> String {
        var lines: [String] = []
        if !p.requestedHosts.isEmpty {
            let everything = p.requestedHosts.contains("<all_urls>") || p.requestedHosts.contains("*://*/*")
            let sites = everything ? "all websites" : p.requestedHosts.joined(separator: ", ")
            lines.append("It can read and change data on: \(sites).")
        }
        if !p.requestedPermissions.isEmpty {
            lines.append("It uses: \(p.requestedPermissions.joined(separator: ", ")).")
        }
        if lines.isEmpty {
            lines.append("This extension requests no special access.")
        }
        lines.append("It never runs in Private or Tor tabs. You can pause or remove it anytime from Settings → Extensions.")
        return lines.joined(separator: "\n\n")
    }
}
