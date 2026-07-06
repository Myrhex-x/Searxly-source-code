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

    var body: some View {
        GeometryReader { geo in
            let columnWidth = (geo.size.width - gutter * CGFloat(columnCount + 1)) / CGFloat(columnCount)

            ScrollView {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        LazyVStack(spacing: gutter) {
                            ForEach(column) { item in
                                MasonryTile(result: item.result, width: columnWidth,
                                            aspect: item.aspect, model: model)
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

                if model.isLoadingMore {
                    ProgressView()
                        .tint(Brand.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
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
                    .onTapGesture { model.open(result) }
                    .contextMenu { ResultContextMenu(result: result, model: model) }
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
