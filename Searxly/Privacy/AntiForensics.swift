//
//  AntiForensics.swift
//  Searxly
//
//  Closes on-disk browsing traces that the OS writes on Searxly's behalf and that Amnesic mode (which
//  only strips the app's OWN persisted state) doesn't reach:
//
//    • Download provenance — macOS tags every download with `com.apple.metadata:kMDItemWhereFroms`
//      (the exact source URL, shown as Finder's "Where from") and a downloaded-date. That URL is a
//      durable browsing trace tattooed onto the file. We strip it on finished downloads in Maximum /
//      Amnesic, while KEEPING `com.apple.quarantine` so Gatekeeper still vets the file.
//    • Window/app state restoration — AppKit persists open windows (and thus tab URLs) to
//      ~/Library/Saved Application State/ so they can be restored next launch. In the no-trace modes we
//      disable that persistence.
//
//  Honest residual (App Sandbox ceiling): system crash reports in ~/Library/Logs/DiagnosticReports and
//  the LSQuarantine SQLite DB are written by the OS outside our container, so a sandboxed app cannot
//  scrub them. We minimize what we hand the OS; we can't reach what it stores elsewhere.
//

import AppKit
import Foundation

enum AntiForensics {

    // MARK: - Download provenance

    /// True when finished downloads should have their source-URL provenance stripped. Scoped to the
    /// Searxly Maximum edition ONLY — this is a paid-edition hardening and must never change the base
    /// app's behaviour, even when the base app is in Maximum Privacy or Amnesic mode.
    @MainActor
    static var stripsDownloadProvenance: Bool { Edition.isMaximum }

    /// Remove the URL-bearing extended attributes from a finished download. Keeps `com.apple.quarantine`
    /// intact so Gatekeeper still checks the file — only the provenance the app doesn't need is scrubbed.
    nonisolated static func stripProvenance(from url: URL) {
        guard url.isFileURL else { return }
        let path = url.path
        for name in ["com.apple.metadata:kMDItemWhereFroms",
                     "com.apple.metadata:kMDItemDownloadedDate"] {
            _ = removexattr(path, name, 0)
        }
    }

    // MARK: - State restoration

    /// True only in the Searxly Maximum edition. Scoped to the paid edition so the base app's window
    /// restoration is never touched — not even in its own Amnesic mode.
    static var disablesStateRestoration: Bool { Edition.isMaximum }

    /// Stop AppKit from persisting open windows (and their tab URLs) to disk for next-launch restoration.
    /// Only ever DISABLES — never force-enables — so it can't override a user who turned restoration off.
    /// Call once, very early in app launch (before any window is created).
    @MainActor
    static func applyStateRestorationPolicy() {
        guard disablesStateRestoration else { return }
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    // MARK: - Clipboard

    /// Searxly Maximum: clear the system pasteboard on quit, so whatever you last copied (a password, a
    /// URL, text lifted from a page) doesn't linger for the next app to read — or get pushed to your other
    /// devices by Universal Clipboard after the browser is closed. Honest limit: while Searxly is running a
    /// copy can still be picked up by Universal Clipboard; macOS exposes no app-level switch to disable it.
    @MainActor
    static func installClipboardHardening() {
        guard Edition.isMaximum else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            NSPasteboard.general.clearContents()
        }
    }

    // MARK: - Opening downloaded files

    /// Searxly Maximum: opening a downloaded file can leave Tor — a document (a PDF, an office file) can
    /// fetch a remote resource the moment it opens, from your REAL IP (Tor Browser's #1 warning). Ask
    /// first. Returns true if the open should proceed. The base app never prompts (always true).
    @MainActor
    static func confirmOpenDownloadedFile(_ url: URL) -> Bool {
        guard Edition.isMaximum else { return true }
        let alert = NSAlert()
        alert.messageText = "Open this downloaded file?"
        alert.informativeText = "“\(url.lastPathComponent)” opens in another app. Some files — PDFs, documents — can quietly connect to the internet when opened, outside Tor, which may reveal your real IP address. If you're unsure, reveal it in Finder and inspect it first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
