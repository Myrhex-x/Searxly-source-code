//
//  SearchResultsView.swift
//  Searxly
//
//  Dedicated container/orchestrator for the entire SERP surface.
//

import SwiftUI

struct SearchResultsView: View {
    let results: [SearXNGResult]
    let currentCategory: String?
    let lastSearchQuery: String
    let glassEnabled: Bool
    let proxyBaseURL: String?
    let highlightedResultURL: String?

    let onClear: () -> Void
    let onSelectCategory: (String?) -> Void
    let onOpenPage: (SearXNGResult) -> Void
    let onOpenInNewTab: (SearXNGResult) -> Void
    let onPreviewMedia: (SearXNGResult) -> Void

    var onLoadMore: (() -> Void)? = nil
    var isLoadingMore: Bool = false
    var canLoadMore: Bool = true

    var knowledgePanelState: KnowledgePanelDisplayState = .hidden
    var onOpenKnowledgeURL: ((String) -> Void)? = nil

    // News SERP controls (news category only)
    var newsTimeRange: String? = nil
    var newsSortByRecency: Bool = false
    var newsLastRefreshed: Date? = nil
    var isLoadingSearch: Bool = false
    var onSelectNewsTimeRange: ((String?) -> Void)? = nil
    var onToggleNewsSort: ((Bool) -> Void)? = nil
    var onRefreshNews: (() -> Void)? = nil

    // Fresh news for the Google-style "Top stories" module injected into the All results.
    var allTabNews: [SearXNGResult] = []

    // Live auto-refresh: count of new stories found in the background (news + Latest), and the merge action.
    var pendingNewsCount: Int = 0
    var onShowPendingNews: (() -> Void)? = nil

    private var dedupedResults: [SearXNGResult] {
        SearXNGResult.deduplicated(results)
    }

    /// News list ordered for display. Top = the ranker's relevance order; Latest = newest-first by parsed
    /// publish time (stable; undated items sink to the bottom). A pure view-layer sort — instant toggle.
    private var newsResults: [SearXNGResult] {
        let base = dedupedResults
        guard newsSortByRecency else { return base }
        // Parse each publish time once, then sort — avoids re-parsing inside every comparison.
        let dated = base.enumerated().map { (offset: $0.offset, result: $0.element, date: $0.element.newsPublishedDate) }
        return dated.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map { $0.result }
    }

    private var categoryTabs: [(label: String, value: String?)] {
        [
            (Localization.string("category_all"), nil),
            (Localization.string("category_news"), "news"),
            (Localization.string("category_images"), "images"),
            (Localization.string("category_videos"), "videos")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serpHeader
                .padding(.horizontal, SERPDesign.listHorizontalPadding)
                .padding(.bottom, 8)

            if !lastSearchQuery.isEmpty || !results.isEmpty {
                SERPCategoryTabs(
                    categories: categoryTabs,
                    selected: currentCategory,
                    glassEnabled: glassEnabled,
                    onSelect: onSelectCategory
                )
                .padding(.horizontal, SERPDesign.listHorizontalPadding - 4)
                .padding(.bottom, 12)
            }

            Divider()
                .opacity(0.35)
                .padding(.horizontal, SERPDesign.listHorizontalPadding)

            resultsBody
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var serpHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if !lastSearchQuery.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lastSearchQuery)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Text("\(dedupedResults.count.formatted()) results")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(Localization.string("results_header_results"))
                        .font(.system(size: 22, weight: .regular))
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if liveNewsCount > 0 {
                        liveNowPill(count: liveNewsCount)
                    }
                    SERPGlassIconButton(
                        systemName: "xmark",
                        glassEnabled: glassEnabled,
                        help: Localization.string("button_clear"),
                        action: onClear
                    )
                }
            }
        }
    }

    /// Number of on-screen news stories published within the last hour (drives the header live pulse).
    private var liveNewsCount: Int {
        guard currentCategory == "news" else { return 0 }
        return dedupedResults.reduce(0) { $0 + ($1.newsFreshness == .live ? 1 : 0) }
    }

    /// "N new stories ↑" — merges the background-fetched stories into the feed on tap.
    private func newNewsStoriesPill(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { onShowPendingNews?() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                Text(
                    count == 1
                        ? Localization.string("news_new_story", defaultValue: "1 new story")
                        : String(format: Localization.string("news_new_stories", defaultValue: "%d new stories"), count)
                )
                .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(SERPDesign.liveRed)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(SERPDesign.liveRed.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(SERPDesign.liveRed.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(Localization.string("news_new_stories_hint", defaultValue: "Show the newest stories"))
    }

    private func liveNowPill(count: Int) -> some View {
        HStack(spacing: 6) {
            PulsingLiveDot(size: 6, color: SERPDesign.liveRed)
            Text(String(format: Localization.string("news_live_now", defaultValue: "%d live now"), count))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SERPDesign.liveRed)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SERPDesign.liveRed.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(SERPDesign.liveRed.opacity(0.35), lineWidth: 0.5))
    }

    // MARK: - Results body

    @ViewBuilder
    private var resultsBody: some View {
        if currentCategory == "images" {
            ImageResultsGrid(
                results: dedupedResults,
                glassEnabled: glassEnabled,
                onOpenPage: onOpenPage,
                onPreview: onPreviewMedia,
                proxyBaseURL: proxyBaseURL,
                onLoadMore: onLoadMore,
                isLoadingMore: isLoadingMore,
                canLoadMore: canLoadMore
            )
        } else if currentCategory == "videos" {
            VideoResultsGrid(
                results: dedupedResults,
                glassEnabled: glassEnabled,
                onOpenPage: onOpenPage,
                onPreview: onPreviewMedia,
                proxyBaseURL: proxyBaseURL,
                onLoadMore: onLoadMore,
                isLoadingMore: isLoadingMore,
                canLoadMore: canLoadMore
            )
        } else if currentCategory == "news" {
            VStack(spacing: 10) {
                NewsControlBar(
                    selectedTimeRange: newsTimeRange,
                    sortByRecency: newsSortByRecency,
                    lastRefreshed: newsLastRefreshed,
                    isRefreshing: isLoadingSearch,
                    glassEnabled: glassEnabled,
                    onSelectTimeRange: { onSelectNewsTimeRange?($0) },
                    onToggleSort: { onToggleNewsSort?($0) },
                    onRefresh: { onRefreshNews?() }
                )
                .frame(maxWidth: SERPDesign.maxListWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SERPDesign.listHorizontalPadding)

                if pendingNewsCount > 0 {
                    newNewsStoriesPill(count: pendingNewsCount)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, SERPDesign.listHorizontalPadding)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                let clusters = newsClusters
                if clusters.isEmpty {
                    newsEmptyState
                } else {
                    let coverage = Dictionary(clusters.map { ($0.lead.url, $0) }, uniquingKeysWith: { first, _ in first })
                    paginatedList(rows: clusters.map(\.lead)) { index, lead in
                        newsClusterRow(index: index, lead: lead, cluster: coverage[lead.url])
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: pendingNewsCount)
        } else {
            paginatedList(
                rows: dedupedResults,
                rowBuilder: { _, result in
                    WebResultRow(
                        result: result,
                        glassEnabled: glassEnabled,
                        query: lastSearchQuery,
                        isHighlighted: highlightedResultURL == result.url,
                        onOpenInNewTab: { onOpenInNewTab(result) }
                    ) {
                        onOpenPage(result)
                    }
                },
                moduleAfterFirst: { topStoriesModule }
            )
        }
    }

    /// The Google-style "Top stories" module for the All tab. Renders only when the parallel news fetch
    /// found fresh, dated stories (see AllTabNewsModule); otherwise it's an EmptyView and nothing shows.
    @ViewBuilder
    private var topStoriesModule: some View {
        if currentCategory == nil, !allTabNews.isEmpty {
            AllTabNewsModule(
                news: allTabNews,
                glassEnabled: glassEnabled,
                query: lastSearchQuery,
                onOpen: onOpenPage,
                onOpenInNewTab: onOpenInNewTab,
                onSeeAllNews: { onSelectCategory("news") }
            )
        }
    }

    /// Shown when the news list is empty — keeps the control bar reachable and offers a one-tap way
    /// to widen a too-narrow time filter.
    @ViewBuilder
    private var newsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(
                newsTimeRange != nil
                    ? Localization.string("news_empty_in_range", defaultValue: "No news in this time range.")
                    : Localization.string("news_empty", defaultValue: "No news found for this search.")
            )
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            if newsTimeRange != nil {
                Button {
                    onSelectNewsTimeRange?(nil)
                } label: {
                    Text(Localization.string("news_show_any_time", defaultValue: "Show any time"))
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SERPDesign.accentGreen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }

    /// News grouped into "full coverage" clusters (same story across outlets), preserving the current
    /// Top/Latest order. Each cluster's lead is the row; its other sources hang off a disclosure.
    private var newsClusters: [NewsCluster] {
        NewsClustering.cluster(newsResults, query: lastSearchQuery)
    }

    /// A clustered news entry: the lead story row plus, when the same story ran elsewhere, a
    /// "Full coverage · N sources" disclosure indented beneath it.
    @ViewBuilder
    private func newsClusterRow(index: Int, lead: SearXNGResult, cluster: NewsCluster?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            newsRow(index: index, result: lead)
            if let cluster, cluster.hasFullCoverage {
                FullCoverageDisclosure(
                    others: cluster.others,
                    totalSources: cluster.sourceCount,
                    glassEnabled: glassEnabled,
                    onOpen: onOpenPage,
                    onOpenInNewTab: onOpenInNewTab
                )
                .padding(.leading, 30)
                .padding(.bottom, 2)
            }
        }
    }

    /// The top story leads with the editorial hero — but ONLY when it has an image. A hero with no
    /// image collapses to a giant floating headline that breaks the list's rhythm, so an imageless
    /// top story renders as a normal compact row and the whole list reads as a clean, uniform feed.
    @ViewBuilder
    private func newsRow(index: Int, result: SearXNGResult) -> some View {
        if index == 0, resultHasThumbnail(result) {
            NewsLeadStoryRow(
                result: result,
                glassEnabled: glassEnabled,
                query: lastSearchQuery,
                isHighlighted: highlightedResultURL == result.url,
                onOpenInNewTab: { onOpenInNewTab(result) }
            ) {
                onOpenPage(result)
            }
        } else {
            NewsResultRow(
                result: result,
                glassEnabled: glassEnabled,
                query: lastSearchQuery,
                isHighlighted: highlightedResultURL == result.url,
                onOpenInNewTab: { onOpenInNewTab(result) }
            ) {
                onOpenPage(result)
            }
        }
    }

    /// Whether a result carries any usable thumbnail URL (gates the image-forward hero treatment).
    private func resultHasThumbnail(_ result: SearXNGResult) -> Bool {
        [result.thumbnail_src, result.thumbnail, result.img_src].contains {
            ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    private var showsKnowledgePanel: Bool {
        !Edition.isMaximum
            && currentCategory != "images"
            && currentCategory != "videos"
    }

    @ViewBuilder
    private func paginatedList<Row: View, Module: View>(
        rows: [SearXNGResult],
        @ViewBuilder rowBuilder: @escaping (Int, SearXNGResult) -> Row,
        @ViewBuilder moduleAfterFirst: @escaping () -> Module = { EmptyView() }
    ) -> some View {
        GeometryReader { geometry in
            let panelFits = geometry.size.width >= SERPDesign.minWidthForKnowledgePanel
            let showPanel = showsKnowledgePanel && panelFits && knowledgePanelState != .hidden

            HStack(alignment: .top, spacing: showPanel ? SERPDesign.knowledgePanelSpacing : 0) {
                ScrollView {
                    resultsList(rows: rows, rowBuilder: rowBuilder, moduleAfterFirst: moduleAfterFirst)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showPanel {
                    let panelHeight = max(
                        geometry.size.height - 8,
                        SERPDesign.knowledgePanelMinContentHeight
                    )
                    ScrollView(.vertical, showsIndicators: false) {
                        knowledgePanelColumn(minHeight: panelHeight)
                    }
                    .frame(width: SERPDesign.knowledgePanelWidth, alignment: .topLeading)
                }
            }
            .padding(.horizontal, SERPDesign.listHorizontalPadding)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func resultsList<Row: View, Module: View>(
        rows: [SearXNGResult],
        @ViewBuilder rowBuilder: @escaping (Int, SearXNGResult) -> Row,
        @ViewBuilder moduleAfterFirst: @escaping () -> Module = { EmptyView() }
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: SERPDesign.resultSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                rowBuilder(index, result)
                    .onAppear {
                        if canLoadMore, !isLoadingMore, index >= rows.count - 3 {
                            onLoadMore?()
                        }
                    }

                if index < rows.count - 1 {
                    Divider()
                        .opacity(0.2)
                        .padding(.leading, 10)
                }

                // Google-style module slot: renders right after the first result (nothing when empty).
                if index == 0 {
                    moduleAfterFirst()
                }
            }

            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.85)
                        .padding(.vertical, 16)
                    Spacer()
                }
            } else if canLoadMore, !rows.isEmpty {
                // Sentinel: fires onLoadMore when it scrolls into view (infinite-scroll trigger).
                Color.clear
                    .frame(height: 40)
                    .onAppear {
                        onLoadMore?()
                    }
            }
        }
        .frame(maxWidth: SERPDesign.maxListWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func knowledgePanelColumn(minHeight: CGFloat) -> some View {
        switch knowledgePanelState {
        case .hidden:
            EmptyView()
        case .loading:
            KnowledgePanelLoadingView(minHeight: minHeight, glassEnabled: glassEnabled)
        case .ready(let content):
            if let openURL = onOpenKnowledgeURL {
                KnowledgePanelView(
                    content: content,
                    proxyBase: proxyBaseURL,
                    minHeight: minHeight,
                    glassEnabled: glassEnabled,
                    onOpenURL: openURL
                )
            }
        }
    }
}