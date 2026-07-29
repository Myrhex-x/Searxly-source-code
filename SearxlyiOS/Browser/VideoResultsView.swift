//
//  VideoResultsView.swift
//  SearxlyiOS
//
//  YouTube-style grid for the Videos scope: 16:9 thumbnails with a play glyph, title and host
//  below — the iOS expression of the macOS VideoResultsGrid. Results without any thumbnail
//  field fall back to a text card so engines that omit thumbs still surface.
//

import SwiftUI

struct VideoResultsView: View {
    let model: BrowserModel
    private var appearance = AppearanceSettings.shared

    init(model: BrowserModel) { self.model = model }

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    VideoCard(result: result) { model.open(result) }
                        .onAppear {
                            if index >= model.results.count - 4 { model.loadMore() }
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if model.isLoadingMore {
                ProgressView()
                    .tint(Brand.textTertiary)
                    .padding(.vertical, 22)
            } else if model.canLoadMore {
                Color.clear.frame(height: 56).accessibilityHidden(true)
            }
        }
        .refreshable { model.runSearch(model.searchQuery) }
    }
}

private struct VideoCard: View {
    let result: SearXNGResult
    let onOpen: () -> Void
    private var appearance = AppearanceSettings.shared

    init(result: SearXNGResult, onOpen: @escaping () -> Void) {
        self.result = result
        self.onOpen = onOpen
    }

    var body: some View {
        let scale = appearance.textScale
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                thumb
                Text(result.title)
                    .font(.system(size: 13.5 * scale, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(result.displayHost)
                    if let date = result.formattedPublishedDate() {
                        Text("· \(date)")
                    }
                }
                .font(.system(size: 11 * scale))
                .foregroundStyle(Brand.textTertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { UIPasteboard.general.string = result.url } label: {
                Label(L("Copy"), systemImage: "doc.on.doc")
            }
            if let url = URL(string: result.url) {
                ShareLink(item: url) { Label(L("Share…"), systemImage: "square.and.arrow.up") }
            }
        }
        .accessibilityLabel("\(result.title), \(result.displayHost)")
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            if SearchMediaURLResolver.hasAnyThumbnailField(result) {
                RemoteThumbView(result: result, keepsPlaceholder: true)
            } else {
                // No thumbnail from the engine — a quiet branded plate keeps the grid rhythm.
                Rectangle().fill(Brand.surface)
                Image(systemName: "play.rectangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Brand.textTertiary)
            }
            // Play affordance over real thumbnails (skip on the placeholder, which has its own glyph).
            if SearchMediaURLResolver.hasAnyThumbnailField(result) {
                Circle()
                    .fill(.black.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    )
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
    }
}
