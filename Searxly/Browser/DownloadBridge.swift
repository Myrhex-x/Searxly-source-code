//
//  DownloadBridge.swift
//  Searxly
//
//  Bridges WebKit file downloads (WKDownload) into the on-screen DownloadsManager store and saves the
//  bytes into the user's Downloads folder (the app holds the files.downloads.read-write entitlement,
//  so no save panel is needed).
//
//  Why a dedicated owner: a WKDownload keeps only a *weak* reference to its delegate, and the per-tab
//  navigation Coordinator that starts a download can be torn down (the user closes the tab) while the
//  transfer is still in flight. The delegate must therefore be owned by something app-lived — this
//  bridge fills that role and releases each delegate when its transfer ends.
//

import WebKit
import os

/// App-lived owner of in-flight downloads. The navigation delegate hands every newly-created
/// `WKDownload` here via `begin(_:)`.
@MainActor
final class DownloadBridge {
    static let shared = DownloadBridge()
    private init() {}

    /// Strong references to active per-download delegates, keyed by the download's identity. Each
    /// proxy is removed when its transfer finishes or fails. WebKit retains the `WKDownload` itself
    /// for the duration of the transfer; we only need to keep its (weakly-referenced) delegate alive.
    private var proxies: [ObjectIdentifier: DownloadProxy] = [:]

    /// Adopt a freshly-created download: give it a long-lived delegate and surface it in the store.
    func begin(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        let proxy = DownloadProxy { [weak self] in
            self?.proxies[key] = nil
        }
        proxies[key] = proxy
        download.delegate = proxy
    }

    /// Picks a non-colliding destination for `suggestedFilename`: ~/Downloads normally, or the
    /// wiped-on-quit session folder during an amnesic session (a file in ~/Downloads would outlive
    /// the session — see `AmnesiaMode.sessionDownloadsDirectory`). WKDownload requires a destination
    /// that does NOT already exist, so colliding names are disambiguated with " (1)", " (2)", … like
    /// Safari. `nonisolated` because it is pure filesystem math and runs from the download delegate
    /// callback.
    nonisolated static func uniqueDownloadsURL(for suggestedFilename: String) -> URL {
        if AmnesiaMode.isActive {
            let dir = AmnesiaMode.sessionDownloadsDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return uniqueURL(in: dir, for: suggestedFilename)
        }
        return uniqueURL(in: permanentDownloadsDirectory(), for: suggestedFilename)
    }

    /// A non-colliding destination in ~/Downloads regardless of amnesic mode — where "Keep" moves a
    /// session-only download so it survives quitting.
    nonisolated static func uniquePermanentURL(for suggestedFilename: String) -> URL {
        uniqueURL(in: permanentDownloadsDirectory(), for: suggestedFilename)
    }

    private nonisolated static func permanentDownloadsDirectory() -> URL {
        let fm = FileManager.default
        return (try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private nonisolated static func uniqueURL(in dir: URL, for suggestedFilename: String) -> URL {
        let fm = FileManager.default

        // Strip any path components a server might smuggle in via the suggested name so the file can
        // never land outside the chosen folder.
        var name = (suggestedFilename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "/" { name = "download" }

        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 1
        repeat {
            let disambiguated = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(disambiguated)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Per-download `WKDownloadDelegate`. Chooses the destination, mirrors byte progress into
/// `DownloadsManager`, and reports completion/failure. Retained by `DownloadBridge` for the lifetime
/// of the transfer (the download's own reference to it is weak).
final class DownloadProxy: NSObject, WKDownloadDelegate {
    private let onFinish: () -> Void
    private var itemID: UUID?
    private var destinationURL: URL?
    private var progressObservation: NSKeyValueObservation?

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let destination = DownloadBridge.uniqueDownloadsURL(for: suggestedFilename)
        self.destinationURL = destination

        // Delegate callbacks are delivered on the main thread, so the store mutation runs inline. We
        // read the new item id back out as a local so the progress closure can capture *that* (a
        // Sendable UUID) instead of `self` — keeping the hop to the main actor concurrency-clean.
        let id: UUID = MainActor.assumeIsolated {
            let item = DownloadsManager.shared.addDownload(
                suggestedFilename: destination.lastPathComponent,
                destination: destination
            )
            self.itemID = item.id
            return item.id
        }

        // Byte progress. The KVO callback can arrive on a background thread, so the store mutation
        // hops to the main actor. Captures only `id` (and the change value) — never self.
        progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
            guard let fraction = change.newValue else { return }
            Task { @MainActor in
                DownloadsManager.shared.updateProgress(for: id, progress: fraction)
            }
        }

        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        complete(success: true, error: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        complete(success: false, error: error.localizedDescription)
    }

    private func complete(success: Bool, error: String?) {
        progressObservation?.invalidate()
        progressObservation = nil
        let finishedURL = destinationURL
        let stripProvenance: Bool = MainActor.assumeIsolated {
            if let id = itemID {
                DownloadsManager.shared.completeDownload(id: id, success: success, error: error)
            }
            onFinish()
            return AntiForensics.stripsDownloadProvenance
        }
        if success {
            // Scrub the source-URL "Where from" tag off the file in the no-trace modes (off-main — it's
            // filesystem I/O and nothing waits on it).
            if stripProvenance, let url = finishedURL {
                Task.detached { AntiForensics.stripProvenance(from: url) }
            }
            // Safety nudge: warn if the finished file can run code (Gatekeeper still vets it on open).
            if let url = finishedURL {
                Task { @MainActor in AntiForensics.warnIfExecutableDownload(url) }
            }
            Log.web.info("Download finished")
        } else {
            Log.web.error("Download failed: \(error ?? "unknown", privacy: .public)")
        }
    }
}
