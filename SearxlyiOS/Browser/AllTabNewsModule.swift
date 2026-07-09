//
//  AllTabNewsModule.swift
//  SearxlyiOS
//
//  Google-style "Top stories" module injected into the All (general) results when the query has fresh
//  news — the iOS twin of the macOS AllTabNewsModule. Adaptive: 3+ fresh stories → a grouped card of 3;
//  1–2 → a single lead card; 0 → nothing. "Fresh" means a genuinely recent, dated story, so the module
//  implies real recency and stays quiet on non-newsy queries. Tapping "More news" jumps to the News tab.
//

import SwiftUI

struct AllTabNewsModule: View {
    let news: [SearXNGResult]
    let query: String
    let onOpen: (SearXNGResult) -> Void
    let onSeeAll: () -> Void

    /// Recent, dated stories only, newest first. Undated results are excluded so the module never
    /// claims a freshness it can't back up.
    private var fresh: [SearXNGResult] {
        news
            .filter {
                switch $0.newsFreshness {
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
                header(title: L("Top stories"))
                ForEach(Array(clusters.prefix(3).enumerated()), id: \.element.id) { index, cluster in
                    if index > 0 {
                        Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 2)
                    }
                    storyRow(cluster, compact: true)
                }
            }
        } else if let lead = clusters.first {
            card {
                header(title: L("In the news"))
                storyRow(lead, compact: false)
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.75)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func header(title: String) -> some View {
        Button(action: onSeeAll) {
            HStack(spacing: 7) {
                Image(systemName: "newspaper")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Brand.text)
                Text(title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Brand.text)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(L("More news"))
                        .scaledFont(size: 12.5)
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 10, weight: .semibold)
                }
                .foregroundStyle(Brand.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 1)
    }

    private func storyRow(_ cluster: NewsCluster, compact: Bool) -> some View {
        let result = cluster.lead
        return Button {
            onOpen(result)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        FaviconView(host: result.displayHost, size: 14)
                        NewsBadge(result: result, compact: true)
                        Text(result.newsSourceName)
                            .scaledFont(size: 12)
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                        if let rel = result.newsRelativeString {
                            Text("·").foregroundStyle(Brand.textTertiary)
                            Text(rel)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(result.newsTimeColor())
                                .lineLimit(1)
                        }
                        if cluster.sourceCount > 1 {
                            Text("·").foregroundStyle(Brand.textTertiary)
                            Text("\(cluster.sourceCount) \(L("sources"))")
                                .scaledFont(size: 12)
                                .foregroundStyle(Brand.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    Text(result.title)
                        .font(.system(size: compact ? 14.5 : 16, weight: .medium))
                        .foregroundStyle(Brand.text)
                        .lineLimit(compact ? 2 : 3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !compact, let snippet = result.newsCleanSnippet, !snippet.isEmpty {
                        Text(snippet)
                            .scaledFont(size: 13)
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if result.rawThumbnailURLString != nil {
                    NewsThumbView(result: result,
                                  requestWidth: compact ? 300 : 360,
                                  requestHeight: compact ? 220 : 264,
                                  cornerRadius: 8)
                        .frame(width: compact ? 76 : 104, height: compact ? 56 : 76)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title), \(result.newsSourceName)")
    }
}
