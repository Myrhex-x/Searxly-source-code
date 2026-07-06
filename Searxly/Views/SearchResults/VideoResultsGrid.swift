//
//  VideoResultsGrid.swift
//  Searxly
//
//  YouTube/Google-like video grid with titles below thumbnails.
//

import SwiftUI
import AppKit

struct VideoResultsGrid: View {
    let results: [SearXNGResult]
    let glassEnabled: Bool
    let onOpenPage: (SearXNGResult) -> Void
    let onPreview: (SearXNGResult) -> Void
    let proxyBaseURL: String?
    var onLoadMore: (() -> Void)? = nil
    var isLoadingMore: Bool = false
    var canLoadMore: Bool = true

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    VideoGridItem(
                        result: result,
                        glassEnabled: glassEnabled,
                        onOpenPage: { onOpenPage(result) },
                        onPreview: { onPreview(result) },
                        proxyBaseURL: proxyBaseURL
                    )
                    .onAppear {
                        if canLoadMore, !isLoadingMore, index >= results.count - 3 {
                            onLoadMore?()
                        }
                    }
                }

                if isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView().scaleEffect(0.85).padding(.vertical, 16)
                        Spacer()
                    }
                    .gridCellColumns(3)
                }
            }
            .padding(.horizontal, SERPDesign.listHorizontalPadding)
            .padding(.vertical, 8)
            .padding(.bottom, 24)
        }
    }
}

private struct VideoGridItem: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedSearchThumbnail(
                    candidates: candidates,
                    referer: result.url,
                    aspectRatio: 16.0 / 9.0,
                    diagnostic: imageDiagnosticInfo
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Duration badge area (resolution as proxy when present)
                VStack {
                    HStack {
                        Spacer()
                        if let res = result.resolution, !res.isEmpty {
                            Text(res)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(8)
                    Spacer()
                }

                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.45), in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    .opacity(isHovering ? 1 : 0.88)
                    .scaleEffect(isHovering ? 1.06 : 1)

                if isHovering {
                    Color.black.opacity(0.22)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .allowsHitTesting(false)

                    HStack(spacing: 8) {
                        Button { onPreview() } label: {
                            Label("Preview", systemImage: "play.rectangle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .glassPill(isProminent: true, tint: SERPDesign.accentGreen, glassEnabled: glassEnabled)

                        Button { onOpenPage() } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                        .glassIcon(size: 32, glassEnabled: glassEnabled)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        AdaptiveChrome.border(colorScheme, dark: isHovering ? 0.14 : 0.06),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: .black.opacity(isHovering ? 0.18 : 0.06), radius: isHovering ? 8 : 3, y: 2)

            HStack(alignment: .top, spacing: 8) {
                FaviconView(pageURL: result.url, size: 20, cornerRadius: 10, loadRemote: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(result.displayHost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        .onTapGesture { onPreview() }
    }
}