//
//  RemoteThumbView.swift
//  SearxlyiOS
//
//  Thumbnail loader for SERP media (image grid, video/news rows). Unlike AsyncImage it walks the
//  ordered candidate list from SearchMediaURLResolver (https-direct → proxy → …), sends browser-ish
//  headers (UA + the result page as Referer — several CDNs 403 bare hotlinks), upgrades http-only
//  candidates to https (ATS blocks plain http for URLSession anyway), skips SVG (UIImage can't
//  decode it), and reports total failure so the grid can drop the tile instead of showing a dead box.
//

import SwiftUI
import UIKit

@MainActor
final class RemoteThumbLoader {
    /// Session-lifetime caches so scrolling back doesn't refetch (or re-fail) thumbnails.
    /// Bounded: ~400 downscaled thumbs ≈ tens of MB worst case, and NSCache evicts under pressure.
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()
    static var failed: Set<String> = []

    static func load(candidates: [URL], referer: String?) async -> UIImage? {
        for raw in normalized(candidates) {
            let key = raw.absoluteString as NSString
            if let hit = cache.object(forKey: key) { return hit }

            var req = URLRequest(url: raw, timeoutInterval: 10)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
            if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
            req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                  data.count > 100,
                  let image = UIImage(data: data) else { continue }
            // Decode once to thumbnail size off the render path: full-resolution photos decoded
            // inside 180pt tiles are a scroll-jank + memory factory.
            let display = await downscaled(image, maxPixel: 700) ?? image
            cache.setObject(display, forKey: key)
            return display
        }
        return nil
    }

    private static func downscaled(_ image: UIImage, maxPixel: CGFloat) async -> UIImage? {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixel else {
            // Already small — still pre-decode off the render path, or the first scroll
            // past the tile pays the full JPEG/PNG decode on the main thread.
            return await image.byPreparingForDisplay() ?? image
        }
        let ratio = maxPixel / longest
        let target = CGSize(width: image.size.width * image.scale * ratio,
                            height: image.size.height * image.scale * ratio)
        return await image.byPreparingThumbnail(ofSize: target)
    }

    /// Drop SVGs, upgrade http→https (and skip the plain-http twin — ATS rejects it for URLSession).
    private static func normalized(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for url in urls {
            if url.path.lowercased().hasSuffix(".svg") { continue }
            var candidate = url
            if url.scheme?.lowercased() == "http" {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = "https"
                guard let upgraded = comps?.url else { continue }
                candidate = upgraded
            }
            if seen.insert(candidate.absoluteString).inserted { out.append(candidate) }
        }
        return out
    }
}

/// A thumbnail that resolves through the candidate list. Renders nothing after total failure
/// (parent layouts collapse naturally) unless `keepsPlaceholder` is set.
struct RemoteThumbView: View {
    let result: SearXNGResult
    var mode: SearchMediaURLResolver.Mode = .gridThumbnail
    var keepsPlaceholder = false

    @State private var image: UIImage?
    @State private var unavailable = false

    private var candidates: [URL] {
        SearchMediaURLResolver.candidateURLs(
            for: result,
            proxyBase: SearchSettings.shared.base,
            mode: mode
        )
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !unavailable {
                Brand.surface
                ProgressView().tint(Brand.textTertiary).controlSize(.small)
            } else if keepsPlaceholder {
                Brand.surface
                Image(systemName: "photo")
                    .scaledFont(size: 18)
                    .foregroundStyle(Brand.textTertiary)
            }
        }
        .task(id: result.id) {
            let key = result.id
            if RemoteThumbLoader.failed.contains(key) {
                unavailable = true
                return
            }
            if let loaded = await RemoteThumbLoader.load(candidates: candidates, referer: result.url) {
                image = loaded
            } else {
                RemoteThumbLoader.failed.insert(key)
                unavailable = true
            }
        }
    }

    var isCollapsed: Bool { unavailable && !keepsPlaceholder }
}
