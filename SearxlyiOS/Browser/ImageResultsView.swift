//
//  ImageResultsView.swift
//  SearxlyiOS
//
//  Image-search results as a two-column masonry (Google/Pinterest style): tiles keep their real
//  aspect ratio, columns are balanced by cumulative height, and tiles whose thumbnails can't be
//  loaded collapse away instead of littering the grid with dead placeholder boxes. Tapping a tile
//  opens the source page; long-press for actions.
//

import SwiftUI
import UIKit

struct ImageResultsView: View {
    let model: BrowserModel

    /// 2 columns on phones, up to 4 on iPad widths.
    @State private var columnCount = 2
    private let gutter: CGFloat = 4

    /// Memoized column split — recomputed when results change, NOT on every render
    /// (re-balancing hundreds of tiles per scroll frame was a measurable jank source).
    @State private var columns: [[MasonryItem]] = []

    /// The image currently shown in the full-screen preview (nil = grid). Tapping a tile previews
    /// the image here first; the source page opens only if the user explicitly asks for it.
    @State private var preview: SearXNGResult?

    var body: some View {
        GeometryReader { geo in
            let columnWidth = (geo.size.width - gutter * CGFloat(columnCount + 1)) / CGFloat(columnCount)

            ScrollView {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        LazyVStack(spacing: gutter) {
                            ForEach(column) { item in
                                MasonryTile(result: item.result, width: columnWidth,
                                            aspect: item.aspect, model: model,
                                            onPreview: { preview = $0 })
                                    .onAppear {
                                        if item.index >= model.results.count - 8 { model.loadMore() }
                                    }
                            }
                        }
                        .frame(width: columnWidth)
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.top, 4)

                // Sentinel re-keys when more tiles land so pagination keeps going past page 2.
                if model.canLoadMore || model.isLoadingMore {
                    Group {
                        if model.isLoadingMore {
                            ProgressView()
                                .tint(Brand.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 22)
                        } else {
                            Color.clear.frame(height: 56)
                        }
                    }
                    .id("img-load-more-\(model.results.count)-\(model.isLoadingMore)")
                    .onAppear { model.loadMore() }
                }

                Color.clear.frame(height: 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { model.runSearch(model.searchQuery) }
            // Safari-like horizontal page flip: swipe the grid left/right to move between scopes.
            .simultaneousGesture(
                DragGesture(minimumDistance: 45)
                    .onEnded { value in
                        guard abs(value.translation.width) > 70,
                              abs(value.translation.height) < 50 else { return }
                        Haptics.tick()
                        model.stepScope(forward: value.translation.width < 0)
                    }
            )
            .onAppear {
                columnCount = Self.columnCount(for: geo.size.width)
                columns = balancedColumns()
            }
            .onChange(of: model.results.count) { columns = balancedColumns() }
            .onChange(of: geo.size.width) { _, width in
                let count = Self.columnCount(for: width)
                if count != columnCount {
                    columnCount = count
                    columns = balancedColumns()
                }
            }
            .fullScreenCover(item: $preview) { result in
                ImagePreviewView(result: result, model: model)
            }
        }
    }

    private static func columnCount(for width: CGFloat) -> Int {
        max(2, min(4, Int(width / 195)))
    }

    struct MasonryItem: Identifiable {
        let result: SearXNGResult
        let aspect: CGFloat
        let index: Int
        var id: String { result.id }
    }

    /// Distribute results across columns, always appending to the currently-shortest one
    /// (cumulative aspect height), so column bottoms stay level.
    private func balancedColumns() -> [[MasonryItem]] {
        var columns = Array(repeating: [MasonryItem](), count: columnCount)
        var heights = Array(repeating: CGFloat(0), count: columnCount)

        for (index, result) in model.results.enumerated() {
            // Skip tiles that already proved unloadable — they'd render as zero-height anyway.
            if RemoteThumbLoader.failed.contains(result.id) { continue }
            let raw = result.thumbnailAspectRatio ?? (4.0 / 3.0)
            let aspect = min(max(raw, 0.5), 2.4)  // clamp pathological ratios
            let target = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            columns[target].append(MasonryItem(result: result, aspect: aspect, index: index))
            heights[target] += 1 / aspect
        }
        return columns
    }
}

// MARK: - Tile

private struct MasonryTile: View {
    let result: SearXNGResult
    let width: CGFloat
    let aspect: CGFloat
    let model: BrowserModel
    let onPreview: (SearXNGResult) -> Void

    @State private var image: UIImage?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: width / aspect)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { onPreview(result) }
                    .contextMenu { ResultContextMenu(result: result, model: model) }
                    // Without a label the whole grid is silent to VoiceOver.
                    .accessibilityLabel(result.title.isEmpty ? result.displayHost : result.title)
                    .accessibilityAddTraits([.isImage, .isButton])
            } else if !unavailable {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.surface)
                    .frame(width: width, height: width / aspect)
            }
            // Unavailable → renders nothing; the column closes the gap on the next layout pass.
        }
        .task(id: result.id) {
            if RemoteThumbLoader.failed.contains(result.id) {
                unavailable = true
                return
            }
            let candidates = SearchMediaURLResolver.candidateURLs(
                for: result,
                proxyBase: SearchSettings.shared.base,
                mode: .gridThumbnail
            )
            if let loaded = await RemoteThumbLoader.load(candidates: candidates, referer: result.url) {
                image = loaded
            } else {
                RemoteThumbLoader.failed.insert(result.id)
                unavailable = true
            }
        }
    }
}

// MARK: - Full-screen preview

/// Tapping an image opens this lightbox — the picture at full size, zoomable — with the source page one
/// explicit tap away. The link is never followed until the user chooses "Open Page".
private struct ImagePreviewView: View {
    let result: SearXNGResult
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    /// Swipe-down-to-dismiss: the picture follows the finger and the chrome fades with it.
    @State private var dismissDrag: CGFloat = 0

    private var dragFade: Double { 1 - min(abs(dismissDrag) / 400, 0.6) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(dragFade)
                .onTapGesture { dismiss() }

            content

            VStack {
                topBar
                Spacer()
                if image != nil || failed { infoBar }
            }
            .opacity(dragFade)
        }
        .task {
            let candidates = SearchMediaURLResolver.candidateURLs(
                for: result, proxyBase: SearchSettings.shared.base, mode: .fullSizePreview
            )
            if let loaded = await RemoteThumbLoader.load(candidates: candidates, referer: result.url, maxPixel: 2200) {
                image = loaded
            } else {
                failed = true
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom * pinch)
                .offset(y: dismissDrag)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(max(zoom * value.magnification, 1), 5) }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3)) { zoom = zoom > 1 ? 1 : 2.5 }
                }
                // Standard lightbox dismissal — but only at rest: while zoomed in, a vertical
                // drag must stay available to future panning, not fling the viewer away.
                .gesture(dismissDragGesture, including: zoom <= 1.01 ? .all : .subviews)
                .accessibilityLabel(result.title.isEmpty ? result.displayHost : result.title)
                .accessibilityAddTraits(.isImage)
        } else if failed {
            VStack(spacing: 10) {
                Image(systemName: "photo").scaledFont(size: 34).foregroundStyle(.white.opacity(0.5))
                Text(L("Couldn't load image")).scaledFont(size: 14).foregroundStyle(.white.opacity(0.7))
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dismissDrag = value.translation.height
            }
            .onEnded { value in
                if abs(dismissDrag) > 120 || abs(value.predictedEndTranslation.height) > 320 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dismissDrag = 0 }
                }
            }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(L("Close"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var infoBar: some View {
        VStack(spacing: 12) {
            VStack(spacing: 3) {
                if !result.title.isEmpty {
                    Text(result.title)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 5) {
                    Text(result.displayHost)
                    if let res = result.resolution, !res.isEmpty { Text("·"); Text(res) }
                }
                .scaledFont(size: 11)
                .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 10) {
                action(L("Open Page"), "safari") { dismiss(); model.open(result) }
                if let url = URL(string: result.url) {
                    ShareLink(item: url) { label(L("Share"), "square.and.arrow.up") }
                }
                action(L("Copy Link"), "doc.on.doc") {
                    UIPasteboard.general.string = result.url
                    Haptics.tick()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { label(title, symbol) }
    }

    private func label(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).scaledFont(size: 17, weight: .medium)
            Text(title).scaledFont(size: 11, weight: .medium)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
