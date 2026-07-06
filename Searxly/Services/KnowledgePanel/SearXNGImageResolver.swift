//
//  SearXNGImageResolver.swift
//  Searxly
//
//  Fallback image source for the knowledge panel. When a Grokipedia article has no usable image, we
//  ask the user's own SearXNG instance for an image of the subject and use the first result. This keeps
//  the lookup private (it goes through the same local/private instance that served the search) and reuses
//  the instance's image_proxy for hotlink-protected sources, exactly like the SERP image grid.
//

import Foundation

enum SearXNGImageResolver {

    /// Returns the first image result for `subject` from the given SearXNG instance, or nil.
    /// The caller turns this into load candidates via `SearchMediaURLResolver`.
    static func firstImageResult(for subject: String, instanceURL: String) async -> SearXNGResult? {
        let query = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        // Prefer IPv4 for the local instance (localhost can resolve to ::1, which SearXNG may not bind).
        var base = instanceURL.hasSuffix("/") ? String(instanceURL.dropLast()) : instanceURL
        base = base.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")

        // safesearch=1: knowledge-panel banners should never surface explicit imagery.
        guard let url = URL(string: "\(base)/search?q=\(encoded)&format=json&categories=images&safesearch=1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Searxly/1.0 (Knowledge Panel; macOS)", forHTTPHeaderField: "User-Agent")
        // Local/private SearXNG instances often run the bot limiter; these headers mirror SearXNGService.
        if base.contains("127.0.0.1") || base.contains("localhost") || base.contains("::1") {
            request.setValue("127.0.0.1", forHTTPHeaderField: "X-Real-IP")
            request.setValue("127.0.0.1", forHTTPHeaderField: "X-Forwarded-For")
        }

        // Same gate as search/autocomplete: the hop is loopback, but SearXNG fetches upstream — so in
        // Maximum Privacy this is only allowed once that upstream traffic is verified routed through
        // the protection network (and a remote instance falls back to the strict native gate).
        guard (try? PrivacyGate.assertSearchEgressAllowed(to: url)) != nil else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearXNGResponse.self, from: data)
        else { return nil }

        // First result that actually carries an image field.
        return decoded.results?.first { SearchMediaURLResolver.hasAnyThumbnailField($0) }
    }
}
