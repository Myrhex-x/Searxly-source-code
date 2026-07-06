//
//  AllTabNewsModule.swift
//  Searxly
//
//  Google-style "Top stories" module injected into the All (general) results when the query has fresh
//  news. Adaptive: 3+ fresh stories → a grouped card of 3; 1–2 → a single lead card; 0 → nothing.
//  "Fresh" means a genuinely recent, dated story (live/today/recent) — undated results never qualify,
//  so the module implies real recency and stays quiet on non-newsy queries.
//

import SwiftUI
import AppKit

struct AllTabNewsModule: View {
    @Environment(\.colorScheme) private var colorScheme

    let news: [SearXNGResult]
    let glassEnabled: Bool
    let query: String
    let onOpen: (SearXNGResult) -> Void
    let onOpenInNewTab: (SearXNGResult) -> Void
    let onSeeAllNews: () -> Void

    /// Recent, dated stories only, newest first. Undated (e.g. bing_news) results are excluded so the
    /// module never claims a freshness it can't back up.
    private var fresh: [SearXNGResult] {
        news
            .filter { r in
                switch r.newsFreshness {
                case .live, .today, .recent: return true
                case .older, .unknown: return false
                }
            }
            .sorted { ($0.newsPublishedDate ?? .distantPast) > ($1.newsPublishedDate ?? .distantPast) }
    }

    var body: some View {
        // Cluster so the module shows distinct stories (each with its source count), not near-duplicates.
        let clusters = NewsClustering.cluster(fresh, query: query)
        if clusters.count >= 3 {
            card {
                header(title: Localization.string("news_top_stories", defaultValue: "Top stories"))
                ForEach(Array(clusters.prefix(3).enumerated()), id: \.element.id) { index, cluster in
                    if index > 0 {
                        Divider().opacity(0.15)
                    }
                    storyRow(cluster, compact: true)
                }
            }
        } else if let lead = clusters.first {
            card {
                header(title: Localization.string("news_in_the_news", defaultValue: "In the news"))
                storyRow(lead, compact: false)
            }
        }
    }

    // MARK: - Card chrome

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same solid panel canvas as the sidebar / news control bar, so the module matches the darkened
        // SERP chrome instead of a light frosted card.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AdaptiveChrome.panelCanvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12, light: 0.10), lineWidth: 0.75)
        )
        .shadow(color: AdaptiveChrome.shadow(colorScheme, darkOpacity: 0.22), radius: 6, x: 0, y: 2)
        // Outer margin lives here (not at the call site) so an empty module adds no stray gap.
        .padding(.vertical, 6)
    }

    private func header(title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "newspaper")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button(action: onSeeAllNews) {
                HStack(spacing: 3) {
                    Text(Localization.string("news_more", defaultValue: "More news"))
                        .font(.system(size: 12.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Localization.string("news_more", defaultValue: "More news"))
        }
        .padding(.bottom, 2)
    }

    // MARK: - Story row

    private func storyRow(_ cluster: NewsCluster, compact: Bool) -> some View {
        let result = cluster.lead
        return Button {
            onOpen(result)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        FaviconView(pageURL: result.url, size: 14, cornerRadius: 3, loadRemote: true)
                        NewsBadge(result: result, compact: true)
                        Text(result.newsSourceName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let rel = result.newsRelativeString {
                            Text("·").foregroundStyle(.quaternary)
                            Text(rel)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(result.newsTimeColor())
                                .lineLimit(1)
                        }
                        if cluster.sourceCount > 1 {
                            Text("·").foregroundStyle(.quaternary)
                            Text(String(format: Localization.string("news_n_sources", defaultValue: "%d sources"), cluster.sourceCount))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Text(result.title)
                        .font(.system(size: compact ? 14 : 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(compact ? 2 : 3)
                        .multilineTextAlignment(.leading)

                    if !compact, let snippet = result.newsCleanSnippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if result.rawThumbnailURLString != nil {
                    CachedSearchThumbnail(
                        candidates: result.newsThumbnailCandidates(width: compact ? 300 : 360, height: compact ? 210 : 252),
                        referer: result.url,
                        aspectRatio: 4.0 / 3.0,
                        useNaturalAspect: true
                    )
                    .frame(width: compact ? 74 : 104, height: compact ? 54 : 76)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.5)
                    )
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Localization.string("search_result_open")) { onOpen(result) }
            Button(Localization.string("search_result_open_new_tab")) { onOpenInNewTab(result) }
            Button(Localization.string("search_result_copy_link")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.url, forType: .string)
            }
        }
        .accessibilityLabel("\(result.title), \(result.newsSourceName)\(result.newsRelativeString.map { ", \($0)" } ?? "")")
    }
}
