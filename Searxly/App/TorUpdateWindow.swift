//
//  TorUpdateWindow.swift
//  Searxly
//
//  The user-facing surface for Tor-routed updates (see TorUpdateChecker). A small standalone window —
//  mirroring AboutWindow — that walks: checking → up-to-date / update-found → downloading → verifying →
//  ready-to-install, all over Tor. Presented from SoftwareUpdater.checkForUpdates() when Maximum Privacy
//  has native egress closed and Tor is the active protection.
//

import AppKit
import SwiftUI

enum TorUpdateWindow {
    /// A single reusable window; re-running a check reuses it rather than stacking windows.
    private static var window: NSWindow?

    @MainActor
    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { await TorUpdateChecker.shared.check() }
            return
        }
        let view = TorUpdateView(onClose: { window?.close() })
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: controller)
        win.title = "Software Update"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 420, height: 260))
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await TorUpdateChecker.shared.check() }
    }
}

struct TorUpdateView: View {
    let onClose: () -> Void
    @State private var checker = TorUpdateChecker.shared

    private var green: Color { SERPDesign.accentGreen }

    var body: some View {
        VStack(spacing: 18) {
            content
        }
        .padding(28)
        .frame(width: 420)
        .frame(minHeight: 240)
    }

    @ViewBuilder
    private var content: some View {
        switch checker.phase {
        case .idle, .checking:
            icon("point.3.connected.trianglepath.dotted", tint: .secondary)
            ProgressView()
            headline("Checking for updates over Tor…")
            subtext("The check travels through Tor so it can’t reveal your real IP address.")

        case .upToDate(let current):
            icon("checkmark.circle.fill", tint: green)
            headline("You’re up to date")
            subtext("\(Edition.appName) \(current) is the latest version.")
            closeButton()

        case .updateFound(let found):
            icon("arrow.down.circle.fill", tint: green)
            headline("Version \(found.shortVersion) is available")
            subtext("It downloads over Tor and is signature-verified before anything is installed.")
            HStack(spacing: 10) {
                Button("Later", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Download & Verify") { Task { await checker.download(found) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)

        case .downloading(let pct):
            icon("arrow.down.circle", tint: .secondary)
            headline("Downloading over Tor…")
            ProgressView(value: Double(pct), total: 100)
                .frame(maxWidth: 260)
            subtext("\(pct)% — transfers over Tor are slower than usual; you can keep browsing.")

        case .verifying:
            icon("checkmark.shield", tint: .secondary)
            ProgressView()
            headline("Verifying signature…")
            subtext("Confirming the download was signed by Searxly and wasn’t tampered with.")

        case .readyToInstall(let version, let fileURL):
            icon("checkmark.seal.fill", tint: green)
            headline("Version \(version) is verified and ready")
            subtext("Open the installer, then drag \(Edition.appName) into your Applications folder to finish.")
            HStack(spacing: 10) {
                Button("Reveal in Finder") { checker.revealAndOpen(fileURL) }
                Button("Open Installer") {
                    checker.revealAndOpen(fileURL)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)

        case .failed(let reason):
            icon("exclamationmark.triangle.fill", tint: .orange)
            headline("Update check couldn’t finish")
            subtext(reason)
            HStack(spacing: 10) {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await checker.check() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Small building blocks

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 40, weight: .regular))
            .foregroundStyle(tint)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .multilineTextAlignment(.center)
    }

    private func subtext(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func closeButton() -> some View {
        Button("Close", action: onClose)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 2)
    }
}
