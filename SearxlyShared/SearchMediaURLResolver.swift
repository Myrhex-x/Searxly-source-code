//
//  SearchMediaURLResolver.swift
//  Searxly
//
//  Shared thumbnail / preview URL resolution for images and videos SERP grids.
//  Consolidates logic previously duplicated across ImageResultsGrid, VideoResultsGrid,
//  and MediaPreviewSheet. Returns an ordered candidate list for retry-on-failure loaders.
//

import Foundation

enum SearchMediaURLResolver {

    enum Mode {
        case gridThumbnail
        case fullSizePreview
    }

    /// Ordered load candidates: HTTPS direct first, then proxy for http-only sources.
    static func candidateURLs(
        for result: SearXNGResult,
        proxyBase: String?,
        mode: Mode
    ) -> [URL] {
        let rawCandidates: [String]
        switch mode {
        case .gridThumbnail:
            rawCandidates = [result.thumbnail, result.thumbnail_src, result.img_src].compactMap { $0 }
        case .fullSizePreview:
            rawCandidates = [result.img_src, result.thumbnail, result.thumbnail_src].compactMap { $0 }
        }

        var seen = Set<String>()
        var urls: [URL] = []

        for raw in rawCandidates {
            let norm = normalize(raw)
            guard !norm.isEmpty, seen.insert(norm).inserted else { continue }

            if let direct = URL(string: norm) {
                if direct.scheme?.lowercased() == "https" {
                    urls.append(direct)
                } else if let base = proxyBase, let proxied = proxiedURL(original: norm, base: base) {
                    urls.append(proxied)
                    urls.append(direct)
                } else {
                    urls.append(direct)
                }
            } else if let base = proxyBase, let proxied = proxiedURL(original: norm, base: base) {
                urls.append(proxied)
            }
        }

        return dedupeURLs(urls)
    }

    static func hasAnyThumbnailField(_ result: SearXNGResult) -> Bool {
        let fields = [result.thumbnail, result.thumbnail_src, result.img_src]
        return fields.contains { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    // MARK: - Private

    private static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("//") { return "https:" + t }
        return t
    }

    private static func proxiedURL(original: String, base: String) -> URL? {
        guard !original.isEmpty,
              let enc = original.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmedBase)/image_proxy?url=\(enc)")
    }

    private static func dedupeURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}