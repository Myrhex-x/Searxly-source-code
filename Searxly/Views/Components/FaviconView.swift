//
//  FaviconView.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Reusable real favicon loader with monogram fallback for premium SERP and UI.
//

import SwiftUI
import AppKit

/// Process-wide, per-HOST favicon cache. A news feed / SERP renders dozens of favicons that mostly share a
/// handful of outlets (many BBC / Reuters / … stories), and most news sites 301 their `/favicon.ico`, so
/// each view otherwise fired ~2 dead requests before reaching the resolver — repeated for every card. This
/// resolves a host's icon ONCE, keeps the decoded image in memory, negative-caches hosts with no icon (→
/// instant monogram, zero requests), and coalesces concurrent loads for the same host into a single fetch.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    private init() {}

    private var images: [String: NSImage] = [:]
    private var negative: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// Already-resolved icon for `host`, if any (synchronous — lets a known outlet paint on the first frame).
    func cachedImage(host: String) -> NSImage? { images[host] }

    /// True when `host` is known to have no obtainable favicon — callers show the monogram with no request.
    func isNegative(host: String) -> Bool { negative.contains(host) }

    /// Resolves and caches the favicon for `host`, walking `candidates` in order. Concurrent callers for the
    /// same host share one load. Returns nil when none resolve (the host is then negative-cached).
    func image(host: String, candidates: [URL]) async -> NSImage? {
        if let img = images[host] { return img }
        if negative.contains(host) { return nil }
        if let existing = inFlight[host] { return await existing.value }
        guard !candidates.isEmpty else { negative.insert(host); return nil }

        let task = Task<NSImage?, Never> { await Self.loadFirst(candidates) }
        inFlight[host] = task
        let image = await task.value
        inFlight.removeValue(forKey: host)
        if let image {
            images[host] = image
        } else {
            negative.insert(host)
        }
        return image
    }

    /// Frees the cached icons (memory pressure / wipe). They simply re-resolve when next shown.
    func purge() {
        images.removeAll()
        negative.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    /// Walks candidate URLs off the main actor, returning the first that decodes to a valid image. Uses the
    /// shared URLSession (same plain, non-Tor path AsyncImage used) — callers gate this to non-Maximum modes.
    nonisolated private static func loadFirst(_ candidates: [URL]) async -> NSImage? {
        for url in candidates {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url)
            request.setValue("Searxly/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { continue }
            return image
        }
        return nil
    }
}

struct FaviconView: View {
    let pageURL: String
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 6

    /// When false, only show the monogram and never make remote requests.
    /// Used for private tabs (and recommended for strong privacy) to avoid any
    /// network requests that could leak visited domains.
    var loadRemote: Bool = true

    @State private var image: NSImage?

    init(pageURL: String, size: CGFloat = 28, cornerRadius: CGFloat = 6, loadRemote: Bool = true) {
        self.pageURL = pageURL
        self.size = size
        self.cornerRadius = cornerRadius
        self.loadRemote = loadRemote
        // Seed from the per-host cache so a known outlet paints its icon on the FIRST frame — no monogram
        // flash while scrolling a feed full of repeated sources. (View inits run on the main actor.)
        let host = URL(string: pageURL)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        if let host, loadRemote, PrivacyManager.shared.appPrivacyMode != .maximum,
           let cached = FaviconCache.shared.cachedImage(host: host) {
            _image = State(initialValue: cached)
        } else {
            _image = State(initialValue: nil)
        }
    }

    private var host: String? {
        guard let url = URL(string: pageURL) else { return nil }
        return url.host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    /// Whether remote favicon requests are permitted right now. Requires the caller to opt in
    /// (`loadRemote`, already false for private tabs) AND the app to be outside Maximum Privacy.
    ///
    /// In Maximum Privacy we never issue a favicon request — favicon loads use a plain URLSession, which is
    /// NOT routed through Tor and NOT covered by the PrivacyGate kill switch, so a request would egress the
    /// visited domain from the user's REAL IP (and, on the fallback, tell a third party which domain we
    /// looked up). Maximum mode therefore shows the monogram instead — "find it locally or don't render it".
    private var allowsRemoteFavicons: Bool {
        loadRemote && PrivacyManager.shared.appPrivacyMode != .maximum
    }

    /// Favicon source strategy:
    ///  1. Direct requests to the target host itself (/favicon.ico, apple-touch-icon, …) — no third party.
    ///  2. A DuckDuckGo icon-service fallback (`icons.duckduckgo.com`), used ONLY when the direct attempts
    ///     fail. This IS a third-party request, so — like every remote favicon request — it is suppressed
    ///     entirely in Maximum Privacy (guarded by `allowsRemoteFavicons`).
    /// The cache walks these in order until one decodes, then remembers the result per host.
    private var faviconURLs: [URL] {
        guard allowsRemoteFavicons, let host else { return [] }
        let h = host.replacingOccurrences(of: "www.", with: "")

        // Never make favicon requests for .onion hosts: they only resolve over Tor (a plain request
        // would fail and could leak the address), so just show the monogram.
        if h.hasSuffix(".onion") { return [] }

        var urls: [URL] = []

        // 1. Direct, privacy-preserving attempts on the target host itself (no third party). Covers
        //    the common case where a site serves an icon at a standard root path. Kept short (2 paths)
        //    so we fall through to the reliable resolver quickly — most news sites 301 their
        //    /favicon.ico and only resolve via <link rel=icon>, which the resolver handles.
        let primaryScheme = pageURLHasHTTPScheme ? "http" : "https"
        for path in ["/favicon.ico", "/apple-touch-icon.png"] {
            if let u = URL(string: "\(primaryScheme)://\(h)\(path)") { urls.append(u) }
        }

        // 2. Third-party resolver fallback (only reached when the direct attempts fail, and never in
        //    Maximum Privacy — `allowsRemoteFavicons` gates the whole method). Many sites declare their
        //    favicon via <link rel="icon"> at a non-standard path (e.g. torproject.org serves no
        //    /favicon.ico) — the direct attempts can't see that without fetching the page. DuckDuckGo's
        //    icon service resolves it (run by DDG, stated no tracking), and is used only for non-private
        //    contexts (loadRemote is already false for private tabs). NOTE: this DOES disclose the looked-up
        //    domain to DDG; it is deliberately skipped entirely in Maximum Privacy.
        if let resolver = URL(string: "https://icons.duckduckgo.com/ip3/\(h).ico") {
            urls.append(resolver)
        }

        return urls
    }

    private var pageURLHasHTTPScheme: Bool {
        guard let url = URL(string: pageURL) else { return false }
        return url.scheme?.lowercased() == "http"
    }

    private var hasValidPageURL: Bool {
        host != nil
    }

    private var domainInitial: String {
        guard let host else { return "•" }
        let cleaned = host.replacingOccurrences(of: "www.", with: "")
        return String(cleaned.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if !hasValidPageURL {
                placeholderIcon(systemName: "globe")
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.opacity)
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        // `.task(id:)` re-runs (auto-cancelling the prior load) whenever the row is recycled to a new URL.
        .task(id: pageURL) {
            await loadFavicon()
        }
    }

    /// Resolves the favicon via the shared per-host cache. Instant for an already-seen outlet; a single
    /// coalesced fetch otherwise. Respects every privacy gate (Maximum mode, `.onion`, `loadRemote`).
    private func loadFavicon() async {
        guard allowsRemoteFavicons, let host, !host.hasSuffix(".onion") else {
            image = nil
            return
        }
        if let cached = FaviconCache.shared.cachedImage(host: host) {
            image = cached
            return
        }
        if FaviconCache.shared.isNegative(host: host) {
            image = nil
            return
        }
        let resolved = await FaviconCache.shared.image(host: host, candidates: faviconURLs)
        // `.task(id:)` cancels on URL change / disappear, so only apply while this load is still current.
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) { image = resolved }
    }

    private func placeholderIcon(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.45))
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var monogram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.55))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)

            Text(domainInitial)
                .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}
