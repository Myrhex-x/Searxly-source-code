//
//  CachedSearchThumbnail.swift
//  Searxly
//
//  Robust image loader for search media grids and preview sheet.
//  URLCache + in-memory cache, sequential candidate retry, shimmer placeholder.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class SearchThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    @Published private(set) var loadedURL: URL?
    @Published private(set) var loadedAspectRatio: CGFloat?

    private static let memoryCache = NSCache<NSString, NSImage>()
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private var loadTask: Task<Void, Never>?

    /// Frees decoded-image memory under memory pressure. Pass `includingDisk` (on .critical) to also
    /// drop the on-disk URL cache. Images simply reload from network/cache when next shown.
    static func purgeCaches(includingDisk: Bool = false) {
        memoryCache.removeAllObjects()
        if includingDisk {
            urlSession.configuration.urlCache?.removeAllCachedResponses()
        }
    }

    func load(candidates: [URL], referer: String?) {
        loadTask?.cancel()
        image = nil
        failed = false
        loadedURL = nil
        loadedAspectRatio = nil

        guard !candidates.isEmpty else {
            failed = true
            return
        }

        isLoading = true

        loadTask = Task {
            for candidate in candidates {
                if Task.isCancelled { return }

                let key = candidate.absoluteString as NSString
                if let cached = Self.memoryCache.object(forKey: key) {
                    self.image = cached
                    self.loadedURL = candidate
                    self.loadedAspectRatio = cached.aspectRatio
                    self.isLoading = false
                    self.failed = false
                    return
                }

                var request = URLRequest(url: candidate)
                request.setValue("Searxly/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
                if let referer, !referer.isEmpty {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }

                do {
                    // Anonymous fetch (a search-result image URL) — rides Tor in Maximum Privacy,
                    // fail-closed otherwise. The Tor lane's session is ephemeral (no disk cache),
                    // so Maximum leaves no thumbnail traces; the direct lane keeps the caching session.
                    guard let lane = await TorLane.current() else { continue }
                    let session = lane.viaTor ? lane.session : Self.urlSession
                    let (data, response) = try await session.data(for: request)
                    if Task.isCancelled { return }
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode),
                          let nsImage = NSImage(data: data),
                          nsImage.isValid else { continue }

                    Self.memoryCache.setObject(nsImage, forKey: key)
                    self.image = nsImage
                    self.loadedURL = candidate
                    self.loadedAspectRatio = nsImage.aspectRatio
                    self.isLoading = false
                    self.failed = false
                    return
                } catch {
                    continue
                }
            }

            if !Task.isCancelled {
                self.isLoading = false
                self.failed = true
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}

struct CachedSearchThumbnail: View {
    let candidates: [URL]
    let referer: String?
    let aspectRatio: CGFloat
    var diagnostic: String? = nil
    var contentMode: ContentMode = .fit
    /// When true, tile height follows the loaded image pixels (no letterboxing). Used by image SERP grid.
    var useNaturalAspect: Bool = false
    /// Optional cap on the natural-aspect height (preview lightbox). The image keeps its true
    /// aspect ratio via scaledToFit and is bounded by both the available width and this height,
    /// so portraits never overflow and nothing is stretched. nil = unbounded (grid behavior).
    var naturalMaxHeight: CGFloat? = nil
    /// Fixed-height banner crop — scales to fill and clips (knowledge panel hero images).
    var fillFrameHeight: CGFloat? = nil

    @StateObject private var loader = SearchThumbnailLoader()

    private var displayAspect: CGFloat {
        if useNaturalAspect, let loaded = loader.loadedAspectRatio, loaded > 0.05, loaded < 20 {
            return loaded
        }
        return aspectRatio
    }

    var body: some View {
        Group {
            if let fillHeight = fillFrameHeight {
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.06)
                        .frame(maxWidth: .infinity)
                        .frame(height: fillHeight)
                        .clipped()
                } else if loader.isLoading {
                    shimmerPlaceholder
                        .frame(maxWidth: .infinity)
                        .frame(height: fillHeight)
                        .overlay(ProgressView().scaleEffect(0.6))
                } else {
                    failurePlaceholder
                        .frame(maxWidth: .infinity)
                        .frame(height: fillHeight)
                }
            } else if let image = loader.image {
                if useNaturalAspect {
                    // Tile height follows real pixels — no letterboxing, no grey gutters.
                    // scaledToFit preserves the true aspect ratio (never stretched); the optional
                    // naturalMaxHeight bounds tall portraits in the preview lightbox.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: naturalMaxHeight)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(displayAspect, contentMode: contentMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if loader.isLoading {
                shimmerPlaceholder
                    .aspectRatio(displayAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(ProgressView().scaleEffect(0.6))
            } else {
                failurePlaceholder
                    .aspectRatio(displayAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .modifier(AspectRatioContainer(
            aspect: displayAspect,
            enabled: fillFrameHeight == nil && (!useNaturalAspect || loader.image == nil)
        ))
        .onAppear {
            loader.load(candidates: candidates, referer: referer)
        }
        .onChange(of: candidates.map(\.absoluteString)) { _, _ in
            loader.load(candidates: candidates, referer: referer)
        }
        .onDisappear {
            loader.cancel()
        }
    }

    private var shimmerPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary.opacity(0.35))
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            )
    }

    private var failurePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.4))
            Image(systemName: "photo")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.5))

            if let d = diagnostic {
                VStack(spacing: 1) {
                    Text("IMG FAIL")
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                    Text(d)
                        .font(.system(size: 5.5, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
                .padding(3)
                .background(Color.black.opacity(0.65))
                .frame(maxWidth: 118)
                .offset(y: 22)
            }
        }
    }
}

/// Applies a fixed aspect box only while loading or for non-natural modes (preview sheet etc.).
private struct AspectRatioContainer: ViewModifier {
    let aspect: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.aspectRatio(aspect, contentMode: .fit)
        } else {
            content
        }
    }
}

private extension NSImage {
    var isValid: Bool {
        size.width > 0 && size.height > 0
    }

    var aspectRatio: CGFloat {
        guard size.height > 0 else { return 1 }
        return size.width / size.height
    }
}