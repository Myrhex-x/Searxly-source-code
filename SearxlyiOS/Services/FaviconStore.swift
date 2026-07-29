//
//  FaviconStore.swift
//  SearxlyiOS
//
//  Safari-style favicon cache. Two fetch paths, both first-party only (NEVER a third-party favicon
//  service, which would centralize browsing metadata):
//    · Visited pages — the page's declared icon (or /favicon.ico), captured on load-finish.
//    · Result hosts on the SERP — a direct anonymous probe of the host's well-known icon paths
//      (ephemeral session, no cookies), so results show real icons. This does contact result hosts
//      before you tap them; the Settings ▸ Search ▸ "Site Icons in Results" toggle turns it off.
//  Everywhere else (suggestions, library, tabs) renders from this local cache, falling back to the
//  monochrome initial chip.
//
//  On disk: Application Support/Searxly/Favicons/<sha256(host)>.png — hashed names so a directory
//  listing doesn't spell out browsing history in plaintext (history itself is encrypted). The whole
//  cache is wiped together with Clear History.
//

import UIKit
import WebKit
import CryptoKit
import Observation

@MainActor
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    /// Bumped whenever an icon lands or the cache is cleared — the one observed property.
    /// Views read it (via `image(for:)`) and re-render when new icons arrive.
    private(set) var generation = 0

    /// Memory cache. `.some(nil)` = known missing (don't re-probe disk every render).
    /// Untracked on purpose: `image(for:)` runs inside view bodies, and mutating observed state
    /// during a view update is illegal — `generation` (mutated only from capture/clear) is the signal.
    @ObservationIgnored private var cache: [String: UIImage?] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Coalesces many simultaneous SERP icon arrivals into one generation bump (one list re-render).
    @ObservationIgnored private var generationFlushTask: Task<Void, Never>?

    private static let iconSize: CGFloat = 64
    private static let refreshAge: TimeInterval = 7 * 24 * 3600
    private static let maxIcons = 500
    private static let maxDownloadBytes = 1_000_000

    private init() {}

    // MARK: - Lookup (cache-only; called from view bodies)

    func image(for host: String) -> UIImage? {
        _ = generation // subscribe the caller to future arrivals
        let key = Self.normalize(host)
        guard !key.isEmpty else { return nil }

        if let cached = cache[key] { return cached }

        // First sighting: probe the disk OFF the main thread (a SERP full of fresh hosts would
        // otherwise do dozens of synchronous file reads mid-scroll), then re-render via generation.
        cache[key] = UIImage?.none
        let path = Self.fileURL(for: key).path
        Task.detached(priority: .userInitiated) {
            let loaded = UIImage(contentsOfFile: path)
            let prepared = await loaded?.byPreparingForDisplay() ?? loaded
            await MainActor.run { [weak self] in
                guard let self, prepared != nil else { return }
                self.cache[key] = prepared
                self.bumpGenerationCoalesced()
            }
        }
        return nil
    }

    // MARK: - Capture (only for the page being visited)

    /// Call when a page finishes loading. Resolves the page's declared icon (or /favicon.ico),
    /// downloads it over an ephemeral session (no cookies), and caches it downscaled.
    func captureIfNeeded(from webView: WKWebView) {
        guard let url = webView.url,
              let scheme = url.scheme, scheme.hasPrefix("http"),
              let rawHost = url.host else { return }
        let key = Self.normalize(rawHost)
        guard !key.isEmpty, !inFlight.contains(key), shouldFetch(key) else { return }

        inFlight.insert(key)
        Task { [weak self, weak webView] in
            defer { self?.inFlight.remove(key) }
            guard let webView else { return }

            var candidates: [URL] = []
            if let href = try? await webView.evaluateJavaScript(Self.iconFinderJS) as? String,
               let declared = URL(string: href) {
                candidates.append(declared)
            }
            candidates.append(URL(string: "\(scheme)://\(rawHost)/favicon.ico")!)

            for candidate in candidates {
                if let icon = await Self.download(candidate) {
                    self?.store(icon, for: key)
                    return
                }
            }
        }
    }

    // MARK: - Result icons (SERP rows; gated by the "Site Icons in Results" setting)

    /// Hosts probed this session that yielded nothing — don't re-hit them on every scroll.
    @ObservationIgnored private var missesThisSession: Set<String> = []

    /// Fetches a result host's icon from its well-known paths (no page DOM available — the user
    /// hasn't visited). No-op when cached, in flight, recently missed, or the setting is off.
    func ensureResultIcon(forHost rawHost: String) async {
        guard ShieldSettings.shared.resultSiteIcons else { return }
        let key = Self.normalize(rawHost)
        guard !key.isEmpty, !inFlight.contains(key), !missesThisSession.contains(key) else { return }
        if image(for: key) != nil, !shouldFetch(key) { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        for path in ["/favicon.ico", "/apple-touch-icon.png"] {
            guard let candidate = URL(string: "https://\(rawHost)\(path)") else { continue }
            if let icon = await Self.download(candidate) {
                store(icon, for: key)
                return
            }
        }
        missesThisSession.insert(key)
    }

    private func shouldFetch(_ key: String) -> Bool {
        let url = Self.fileURL(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > Self.refreshAge
    }

    private func store(_ icon: UIImage, for key: String) {
        guard let data = icon.pngData() else { return }
        let dir = Self.directory()
        try? data.write(to: Self.fileURL(for: key), options: [.atomic, .completeFileProtection])
        cache[key] = icon
        bumpGenerationCoalesced()
        Self.pruneIfNeeded(in: dir)
    }

    /// One generation tick for a burst of icons (SERP loads ~10 hosts at once). Immediate clear still
    /// publishes right away so the UI drops stale glyphs without waiting.
    private func bumpGenerationCoalesced() {
        if generationFlushTask != nil { return }
        generationFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else { return }
            self.generationFlushTask = nil
            self.generation += 1
        }
    }

    /// Wipes every cached icon (called alongside Clear History — favicons are browsing traces too).
    func clearAll() {
        generationFlushTask?.cancel()
        generationFlushTask = nil
        try? FileManager.default.removeItem(at: Self.directory())
        cache.removeAll()
        generation += 1
    }

    // MARK: - Download + normalize

    private static func download(_ url: URL) async -> UIImage? {
        let config = URLSessionConfiguration.ephemeral // no cookies, no shared cache
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= maxDownloadBytes,
              let raw = UIImage(data: data),
              min(raw.size.width, raw.size.height) >= 8 else { return nil }
        return downscale(raw)
    }

    /// Renders into a square canvas at 64pt, preserving aspect (icons stay crisp, tiny on disk).
    private static func downscale(_ image: UIImage) -> UIImage {
        let side = iconSize
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: drawSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: drawSize))
        }
    }

    // MARK: - Disk layout

    static func normalize(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Searxly/Favicons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory().appendingPathComponent("\(digest).png")
    }

    private static func pruneIfNeeded(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > maxIcons else { return }

        let dated = files.compactMap { url -> (URL, Date)? in
            guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (url, d)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxIcons) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Best declared icon on the page: prefers apple-touch icons, then the largest sized <link icon>.
    private static let iconFinderJS = """
    (function () {
        var links = document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]');
        var best = null, bestScore = -1;
        for (var i = 0; i < links.length; i++) {
            var l = links[i];
            if (!l.href) continue;
            var score = 0;
            var rel = (l.getAttribute('rel') || '').toLowerCase();
            if (rel.indexOf('apple-touch') !== -1) score += 100;
            var sizes = (l.getAttribute('sizes') || '').split('x')[0];
            score += Math.min(parseInt(sizes, 10) || 0, 192);
            if (score > bestScore) { bestScore = score; best = l.href; }
        }
        return best;
    })();
    """
}
