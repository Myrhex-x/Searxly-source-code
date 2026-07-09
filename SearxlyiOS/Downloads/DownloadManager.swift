//
//  DownloadManager.swift
//  SearxlyiOS
//
//  File downloads, Safari-style. The navigation delegate hands a WKDownload here (when a response is an
//  attachment or the browser can't display it); we stream it to a private Downloads folder in the app
//  container, track live progress, and keep an encrypted index of finished files. Downloaded files stay
//  in the sandbox — the user exports them with the share sheet / "Save to Files"; nothing is uploaded,
//  synced, or exposed until they choose to. The Downloads dir is excluded from iCloud backup (App Store
//  best practice: re-downloadable content shouldn't bloat backups).
//

import Foundation
import Observation
import WebKit
import UIKit

@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// A finished file on disk (metadata only — persisted encrypted; the bytes live in the Downloads dir).
    struct Completed: Identifiable, Codable, Equatable {
        let id: UUID
        let filename: String
        let sourceURL: String
        let byteCount: Int64
        let finishedAt: Date
        /// Name within the Downloads dir (kept relative so the container can move between launches).
        let storedName: String
    }

    /// An in-flight download. A struct updated in place — the list is small, so per-tick re-renders are fine.
    struct Active: Identifiable, Equatable {
        let id: UUID
        var filename: String
        var storedName: String
        var fraction: Double
        var bytesWritten: Int64
        var totalBytes: Int64
        var failed: Bool
        var canResume: Bool
    }

    private(set) var active: [Active] = []
    private(set) var completed: [Completed] = []

    /// Bumps whenever a new download begins, so the browser shell can surface the Downloads sheet.
    private(set) var startedGeneration = 0

    /// WKDownload holds its delegate weakly — we must retain the coordinators ourselves.
    private var coordinators: [UUID: DownloadCoordinator] = [:]
    /// Resume data captured on failure, for a future Retry.
    private var resumeData: [UUID: Data] = [:]

    private static let indexName = "Downloads.enc"
    private static let completedCap = 200

    private init() {
        let loaded = SecureLibraryStorage.load([Completed].self, from: Self.indexURL) ?? []
        // Drop index entries whose file has since been deleted (manual purge, storage cleanup).
        completed = loaded.filter { FileManager.default.fileExists(atPath: Self.downloadsDir.appendingPathComponent($0.storedName).path) }
        if completed.count != loaded.count { persist() }
    }

    var hasActive: Bool { active.contains { !$0.failed } }
    var badgeCount: Int { active.count }

    // MARK: - Background execution (keep transfers alive briefly after the app is backgrounded)

    /// A background-task assertion held while any download is in flight. WKDownload runs in-process,
    /// so a suspended app stalls it — this asks iOS for extra time so a download can finish (or reach
    /// a resumable checkpoint) after the user leaves the app. It's a short grace period, not unlimited:
    /// a very large transfer can still be interrupted, in which case it resumes from `resumeData` on
    /// Retry. Released the instant nothing is downloading, so it never keeps the app awake needlessly.
    @ObservationIgnored private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func refreshBackgroundAssertion() {
        if hasActive {
            guard bgTask == .invalid else { return }
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "SearxlyDownloads") { [weak self] in
                self?.endBackgroundAssertion()   // time expired — release so the app isn't killed
            }
        } else {
            endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - WKDownload intake (called from the navigation delegate)

    /// Registers a new download and returns its delegate (retained here). The filename is filled in
    /// once WebKit resolves the destination.
    func begin(_ download: WKDownload) -> DownloadCoordinator {
        let id = UUID()
        active.insert(Active(id: id, filename: L("Download"), storedName: "",
                             fraction: 0, bytesWritten: 0, totalBytes: 0,
                             failed: false, canResume: false), at: 0)
        let coordinator = DownloadCoordinator(id: id, manager: self)
        coordinators[id] = coordinator
        startedGeneration &+= 1
        Haptics.tick()
        refreshBackgroundAssertion()
        return coordinator
    }

    /// Picks a unique, sanitized destination inside the Downloads dir and records the resolved filename.
    func destination(for id: UUID, suggestedFilename: String, response: URLResponse) -> URL? {
        let base = Self.sanitize(suggestedFilename.isEmpty ? (response.suggestedFilename ?? "download") : suggestedFilename)
        let unique = Self.uniqueName(for: base)
        if let idx = active.firstIndex(where: { $0.id == id }) {
            active[idx].filename = unique
            active[idx].storedName = unique
            active[idx].totalBytes = max(0, response.expectedContentLength)
        }
        return Self.downloadsDir.appendingPathComponent(unique)
    }

    func updateProgress(id: UUID, fraction: Double, written: Int64, total: Int64) {
        guard let idx = active.firstIndex(where: { $0.id == id }) else { return }
        active[idx].fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        active[idx].bytesWritten = written
        if total > 0 { active[idx].totalBytes = total }
    }

    func finish(id: UUID) {
        coordinators[id] = nil
        resumeData[id] = nil
        guard let idx = active.firstIndex(where: { $0.id == id }) else { return }
        let item = active.remove(at: idx)
        // The on-disk size is authoritative — servers that stream chunked (no Content-Length) leave the
        // reported byte counts at 0, which would otherwise show "Zero KB" for a perfectly good file.
        let onDisk = (try? Self.downloadsDir.appendingPathComponent(item.storedName)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let byteCount = Int64(onDisk ?? 0) > 0
            ? Int64(onDisk ?? 0)
            : (item.totalBytes > 0 ? item.totalBytes : item.bytesWritten)
        completed.insert(Completed(id: id, filename: item.filename, sourceURL: "",
                                   byteCount: byteCount, finishedAt: .now, storedName: item.storedName), at: 0)
        if completed.count > Self.completedCap {
            for stale in completed.suffix(completed.count - Self.completedCap) { deleteFile(stale.storedName) }
            completed.removeLast(completed.count - Self.completedCap)
        }
        persist()
        refreshBackgroundAssertion()
        Haptics.success()
    }

    func fail(id: UUID, error: Error, resumeData data: Data?) {
        guard let idx = active.firstIndex(where: { $0.id == id }) else { return }
        active[idx].failed = true
        active[idx].canResume = data != nil
        resumeData[id] = data
        // Don't drop the coordinator yet — a Retry reuses nothing from it, but keep the row until dismissed.
        refreshBackgroundAssertion()
    }

    // MARK: - User actions

    func fileURL(for item: Completed) -> URL {
        Self.downloadsDir.appendingPathComponent(item.storedName)
    }

    func removeActive(_ id: UUID) {
        coordinators[id] = nil
        resumeData[id] = nil
        active.removeAll { $0.id == id }
        refreshBackgroundAssertion()
    }

    func removeCompleted(_ item: Completed) {
        deleteFile(item.storedName)
        completed.removeAll { $0.id == item.id }
        persist()
    }

    func clearCompleted() {
        for item in completed { deleteFile(item.storedName) }
        completed.removeAll()
        persist()
    }

    // MARK: - Storage

    private func deleteFile(_ storedName: String) {
        guard !storedName.isEmpty else { return }
        try? FileManager.default.removeItem(at: Self.downloadsDir.appendingPathComponent(storedName))
    }

    private func persist() {
        SecureLibraryStorage.save(completed, to: Self.indexURL)
    }

    private static var indexURL: URL { SecureLibraryStorage.fileURL(name: indexName) }

    /// Application Support/Searxly/Downloads (created on first use, excluded from iCloud backup).
    static let downloadsDir: URL = {
        let dir = SecureLibraryStorage.fileURL(name: "Downloads")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }()

    /// Strips path separators / control characters so a hostile Content-Disposition can't escape the dir.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "..", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? "download" : trimmed
    }

    /// Appends " (1)", " (2)", … before the extension when a name already exists on disk.
    private static func uniqueName(for name: String) -> String {
        let fm = FileManager.default
        let dir = downloadsDir
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    #if DEBUG
    /// Seeds a fake finished download so the Downloads UI is verifiable headlessly.
    func seedDemo() {
        guard completed.isEmpty else { return }
        let name = "Searxly-Privacy-Report.pdf"
        let url = Self.downloadsDir.appendingPathComponent(name)
        try? Data("%PDF-1.4 demo".utf8).write(to: url)
        completed = [Completed(id: UUID(), filename: name, sourceURL: "https://searxly.app",
                               byteCount: 428_713, finishedAt: .now, storedName: name)]
        active = [Active(id: UUID(), filename: "ubuntu-24.04.iso", storedName: "ubuntu-24.04.iso",
                         fraction: 0.42, bytesWritten: 1_509_949_440, totalBytes: 3_595_120_000,
                         failed: false, canResume: false)]
    }
    #endif
}

// MARK: - Per-download delegate

/// WKDownloadDelegate for one download. Retained by the manager (WKDownload keeps its delegate weakly).
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    let id: UUID
    weak var manager: DownloadManager?
    private var progressObservation: NSKeyValueObservation?

    init(id: UUID, manager: DownloadManager) {
        self.id = id
        self.manager = manager
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        MainActor.assumeIsolated {
            let destination = manager?.destination(for: id, suggestedFilename: suggestedFilename, response: response)
            // Progress KVO can fire off the main thread — capture values, then hop to the main actor.
            progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                let written = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.manager?.updateProgress(id: self.id, fraction: fraction, written: written, total: total)
                }
            }
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            progressObservation = nil
            manager?.finish(id: id)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            progressObservation = nil
            manager?.fail(id: id, error: error, resumeData: resumeData)
        }
    }
}
