//
//  FaviconView.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Reusable real favicon loader with monogram fallback for premium SERP and UI.
//

import SwiftUI

struct FaviconView: View {
    let pageURL: String
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 6

    /// When false, only show the monogram and never make remote requests.
    /// Used for private tabs (and recommended for strong privacy) to avoid any
    /// network requests that could leak visited domains.
    var loadRemote: Bool = true

    @State private var loadFailed = false
    @State private var currentFaviconURL: URL?

    private var host: String? {
        guard let url = URL(string: pageURL) else { return nil }
        return url.host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    /// Strict privacy favicon strategy (no third parties):
    /// Try several common direct favicon locations on the target host only (in order).
    /// On any failure AsyncImage phase triggers tryNextFaviconSource which advances
    /// through the list until success or exhaustion (then monogram).
    /// No third-party favicon services (no s2.googleusercontent, no external CDNs).
    /// This eliminates any network request that could leak the domains the user is visiting.
    private var faviconURLs: [URL] {
        guard let host else { return [] }
        let h = host.replacingOccurrences(of: "www.", with: "")

        // Never make favicon requests for .onion hosts: they only resolve over Tor (a plain request
        // would fail and could leak the address), so just show the monogram.
        if h.hasSuffix(".onion") { return [] }

        var urls: [URL] = []

        // 1. Direct, privacy-preserving attempts on the target host itself (no third party). Covers
        //    the common case where a site serves /favicon.ico at the root.
        let primaryScheme = pageURLHasHTTPScheme ? "http" : "https"
        for path in ["/favicon.ico", "/apple-touch-icon.png", "/favicon.png", "/favicon.svg"] {
            if let u = URL(string: "\(primaryScheme)://\(h)\(path)") { urls.append(u) }
        }

        // 2. Resolver fallback (only reached when the direct attempts fail). Many sites declare their
        //    favicon via <link rel="icon"> at a non-standard path (e.g. torproject.org serves no
        //    /favicon.ico) — the direct attempts can't see that without fetching the page. DuckDuckGo's
        //    icon service resolves it. It is privacy-respecting (run by DDG, stated no tracking) and is
        //    only used for non-private contexts (loadRemote is already false for private tabs).
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
            } else if loadRemote && !loadFailed, let faviconURL = currentFaviconURL ?? faviconURLs.first {
                AsyncImage(url: faviconURL, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            .onAppear {
                                loadFailed = false
                                currentFaviconURL = faviconURL
                            }

                    case .failure:
                        Color.clear
                            .onAppear {
                                tryNextFaviconSource()
                            }

                    case .empty:
                        monogram

                    @unknown default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .id(pageURL)
        .onChange(of: pageURL) { _, _ in
            resetFaviconState()
        }
        .onAppear {
            resetFaviconState()
        }
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

    private func tryNextFaviconSource() {
        let all = faviconURLs

        if let current = currentFaviconURL,
           let index = all.firstIndex(of: current),
           index + 1 < all.count {
            // Try the next one
            currentFaviconURL = all[index + 1]
            loadFailed = false
        } else {
            // No more sources to try
            loadFailed = true
            currentFaviconURL = nil
        }
    }

    private func resetFaviconState() {
        loadFailed = false
        currentFaviconURL = nil
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
