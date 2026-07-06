//
//  ImageResultsGrid.swift
//  Searxly
//
//  Google-like masonry image grid: variable-height tiles, natural aspect ratios, no card chrome.
//

import SwiftUI
import AppKit

struct ImageResultsGrid: View {
    let results: [SearXNGResult]
    let glassEnabled: Bool
    let onOpenPage: (SearXNGResult) -> Void
    let onPreview: (SearXNGResult) -> Void
    let proxyBaseURL: String?
    var onLoadMore: (() -> Void)? = nil
    var isLoadingMore: Bool = false
    var canLoadMore: Bool = true

    private let columnSpacing: CGFloat = 10
    private let rowSpacing: CGFloat = 10
    private let horizontalPadding: CGFloat = 16
    /// Target column width — drives how many masonry columns fit (Google-like density).
    private let targetColumnWidth: CGFloat = 210

    var body: some View {
        GeometryReader { geo in
            let available = max(geo.size.width - horizontalPadding * 2, targetColumnWidth)
            let columnCount = max(2, Int((available + columnSpacing) / (targetColumnWidth + columnSpacing)))
            let columns = distribute(results, columnCount: columnCount)

            ScrollView {
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        LazyVStack(spacing: rowSpacing) {
                            ForEach(Array(columns[columnIndex].enumerated()), id: \.element.id) { index, result in
                                ImageGridItem(
                                    result: result,
                                    glassEnabled: glassEnabled,
                                    onOpenPage: { onOpenPage(result) },
                                    onPreview: { onPreview(result) },
                                    proxyBaseURL: proxyBaseURL
                                )
                                .onAppear {
                                    if let globalIndex = results.firstIndex(where: { $0.id == result.id }),
                                       canLoadMore, !isLoadingMore, globalIndex >= results.count - 4 {
                                        onLoadMore?()
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)

                if isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView().scaleEffect(0.8).padding(.vertical, 12)
                        Spacer()
                    }
                }
            }
        }
    }

    /// Round-robin distribution into masonry columns (shortest-column approximation for mixed aspects).
    private func distribute(_ items: [SearXNGResult], columnCount: Int) -> [[SearXNGResult]] {
        guard columnCount > 0 else { return [] }
        var columns = Array(repeating: [SearXNGResult](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)

        for item in items {
            let aspect = item.thumbnailAspectRatio ?? (4.0 / 3.0)
            let estimatedHeight = 1.0 / max(aspect, 0.2)
            let target = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            columns[target].append(item)
            heights[target] += estimatedHeight
        }
        return columns
    }
}

private struct ImageGridItem: View {
    let result: SearXNGResult
    let glassEnabled: Bool
    let onOpenPage: () -> Void
    let onPreview: () -> Void
    let proxyBaseURL: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var candidates: [URL] {
        SearchMediaURLResolver.candidateURLs(for: result, proxyBase: proxyBaseURL, mode: .gridThumbnail)
    }

    private var imageDiagnosticInfo: String? {
        guard DeveloperSettings.shared.isEnabled else { return nil }
        if let first = candidates.first {
            let via = first.absoluteString.contains("/image_proxy") ? "proxy" : "direct"
            return "\(via):\(first.absoluteString)"
        }
        return "no-candidate"
    }

    private var fallbackAspect: CGFloat {
        if let ar = result.thumbnailAspectRatio, ar > 0.1, ar < 20 { return ar }
        return 4.0 / 3.0
    }

    private var displayHost: String { result.displayHost }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedSearchThumbnail(
                candidates: candidates,
                referer: result.url,
                aspectRatio: fallbackAspect,
                diagnostic: imageDiagnosticInfo,
                useNaturalAspect: true
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)

            VStack {
                if let res = result.resolution, !res.isEmpty {
                    HStack {
                        Spacer()
                        Text(res)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    .padding(6)
                }
                Spacer()
                if !displayHost.isEmpty {
                    HStack(spacing: 5) {
                        FaviconView(pageURL: result.url, size: 12, cornerRadius: 2, loadRemote: true)
                        Text(displayHost)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
                }
            }

            if isHovering {
                Color.black.opacity(0.2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Button { onPreview() } label: {
                        Image(systemName: "eye.fill")
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .glassIcon(size: 32, glassEnabled: glassEnabled)

                    Button { onOpenPage() } label: {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .glassIcon(size: 32, glassEnabled: glassEnabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    AdaptiveChrome.border(colorScheme, dark: isHovering ? 0.18 : 0.05),
                    lineWidth: 0.5
                )
        )
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .shadow(color: .black.opacity(isHovering ? 0.22 : 0.07), radius: isHovering ? 8 : 3, x: 0, y: 2)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        .onTapGesture { onPreview() }
    }
}