//
//  NewsFeedUI.swift
//  SearxlyiOS
//
//  The visual kit for the start-page news feed: the LIVE / BREAKING badge, a news-optimized thumbnail
//  loader, and the two card shapes — a large top-story hero and the compact topic rows. Monochrome
//  "expensive calm" like the SERP; the one accent is broadcast-red news urgency (LIVE / BREAKING /
//  sub-hour timestamps), mirroring the macOS app. Everything reads on the forced-dark start page.
//

import SwiftUI
import UIKit

// MARK: - Live / Breaking badge

/// LIVE (fresh < 1h) or BREAKING (headline-flagged, not stale) chyron chip. Renders nothing otherwise.
/// BREAKING takes precedence — it's the stronger editorial signal.
struct NewsBadge: View {
    let result: SearXNGResult
    var compact: Bool = false

    var body: some View {
        if result.isBreakingNews {
            chip(text: L("BREAKING"), dot: false)
        } else if result.newsFreshness == .live {
            chip(text: L("LIVE"), dot: true)
        }
    }

    private func chip(text: String, dot: Bool) -> some View {
        HStack(spacing: compact ? 3.5 : 4) {
            if dot { PulsingLiveDot(size: compact ? 4.5 : 5.5, color: .white) }
            Text(text)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 2.5)
        .background(Brand.liveRed, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A gently pulsing dot for the LIVE badge. Honors Reduce Motion (falls back to a steady dot).
struct PulsingLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 6
    var color: Color = Brand.liveRed

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(pulsing ? 1.0 : 0.62)
            .opacity(pulsing ? 1.0 : 0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityHidden(true)
    }
}

extension SearXNGResult {
    /// Timestamp tint: red while the story is live (< 1h) to reinforce "now"; muted once it ages,
    /// so red stays meaningful instead of decorative.
    func newsTimeColor() -> Color {
        newsFreshness == .live ? Brand.liveRed : Brand.textTertiary
    }
}

// MARK: - News thumbnail

/// A story photo resolved through the news-sized candidate list (bing/google upscaled), reusing the
/// SERP RemoteThumbLoader (browser headers, referer, off-thread downscale, session cache). Shows a
/// quiet placeholder while loading / on failure — the parent decides whether to reserve the slot.
struct NewsThumbView: View {
    let result: SearXNGResult
    let requestWidth: Int
    let requestHeight: Int
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Brand.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "newspaper")
                    .scaledFont(size: 17, weight: .regular)
                    .foregroundStyle(Brand.textTertiary)
            } else {
                ProgressView().controlSize(.small).tint(Brand.textTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
        .task(id: result.id) {
            let candidates = result.newsThumbnailCandidates(width: requestWidth, height: requestHeight)
            guard !candidates.isEmpty else { failed = true; return }
            if let loaded = await RemoteThumbLoader.load(candidates: candidates, referer: result.url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

// MARK: - Top-story hero

/// The single most important story, a large full-width banner atop the feed.
struct HomeTopStoryHero: View {
    let cluster: NewsCluster
    let onOpen: (SearXNGResult) -> Void

    private var lead: SearXNGResult { cluster.lead }

    private var badge: (text: String, dot: Bool) {
        if lead.isBreakingNews { return (L("BREAKING"), false) }
        if lead.newsFreshness == .live { return (L("LIVE"), true) }
        return (L("TOP STORY"), false)
    }

    var body: some View {
        Button { onOpen(lead) } label: {
            VStack(alignment: .leading, spacing: 12) {
                NewsThumbView(result: lead, requestWidth: 1000, requestHeight: 560, cornerRadius: 16)
                    .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            if badge.dot { PulsingLiveDot(size: 6, color: .white) }
                            Text(badge.text)
                                .scaledFont(size: 11.5, weight: .bold)
                                .tracking(0.6)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Brand.liveRed, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(12)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    sourceLine(size: 13)
                    Text(lead.title)
                        .scaledFont(size: 22, weight: .semibold)
                        .foregroundStyle(Brand.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let snippet = lead.newsCleanSnippet, !snippet.isEmpty {
                        Text(snippet)
                            .scaledFont(size: 14.5)
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if cluster.sourceCount > 1 {
                        Text("\(L("Full coverage")) · \(cluster.sourceCount) \(L("sources"))")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(Brand.textTertiary)
                            .padding(.top, 1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { NewsContextMenu(result: lead) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.text): \(lead.title), \(lead.newsSourceName)")
    }

    private func sourceLine(size: CGFloat) -> some View {
        HStack(spacing: 7) {
            FaviconView(host: lead.displayHost, size: 16)
            Text(lead.newsSourceName)
                .font(.system(size: size))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(1)
            if let rel = lead.newsRelativeString {
                Text("·").foregroundStyle(Brand.textTertiary)
                Text(rel)
                    .font(.system(size: size - 0.5, weight: lead.newsFreshness == .live ? .semibold : .regular))
                    .foregroundStyle(lead.newsTimeColor())
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Topic section

/// A topic block: a header (icon + name + "See all") over a small stack of compact story rows. A
/// vertical stack — not a horizontal carousel — so the page scroll stays native-smooth on touch.
struct HomeTopicSection: View {
    let topic: HomeNewsFeed.Topic
    var feed: HomeNewsFeed
    let onOpen: (SearXNGResult) -> Void
    let onSeeAll: (String) -> Void

    /// How many rows a topic shows on the home (See all opens the full news search).
    private let visibleCount = 4

    var body: some View {
        // nil = not attempted (reserve height + trigger load); [] = resolved empty. `display` is the
        // cross-topic-deduped list actually shown. If everything was claimed by a higher topic, the
        // whole section collapses.
        let resolved = feed.stories[topic.id]
        let isLoading = feed.loading.contains(topic.id)
        // Drop the story already shown as the hero banner so it never repeats right below it.
        let heroKey = feed.topStory.map { SearchResultProcessor.canonicalURLKey($0.lead.url) }
        let display = Array(
            feed.dedupedStories(for: topic.id)
                .filter { heroKey == nil || SearchResultProcessor.canonicalURLKey($0.url) != heroKey }
                .prefix(visibleCount)
        )

        if resolved == nil || isLoading || !display.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header
                if display.isEmpty {
                    ForEach(0..<2, id: \.self) { _ in placeholderRow }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(display.enumerated()), id: \.element.id) { index, result in
                            if index > 0 {
                                Rectangle().fill(Brand.hairline).frame(height: 0.5)
                                    .padding(.leading, 4)
                            }
                            HomeNewsRow(result: result, onOpen: onOpen)
                        }
                    }
                }
            }
            .animation(.easeOut(duration: 0.28), value: display.count)
            .onAppear { feed.loadIfNeeded(topic) }
        }
    }

    private var header: some View {
        Button { onSeeAll(topic.query) } label: {
            HStack(spacing: 8) {
                Image(systemName: topic.systemIcon)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 20)
                Text(L(topic.label))
                    .scaledFont(size: 19, weight: .semibold)
                    .foregroundStyle(Brand.text)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Brand.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L(topic.label)) — \(L("See all"))")
    }

    private var placeholderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(width: 90, height: 10)
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(height: 15)
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(width: 180, height: 15)
            }
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 10).fill(Brand.surface).frame(width: 92, height: 70)
        }
        .padding(.vertical, 11)
        .redacted(reason: .placeholder)
    }
}

// MARK: - Compact story row

/// The visual of one story row — source · time + headline on the left, a thumbnail on the right
/// (reserved only when the result actually has one). No tap handling of its own, so it can sit inside
/// the home feed's Button *and* the SERP List's row (which brings its own Button + swipe actions).
struct NewsRowContent: View {
    let result: SearXNGResult
    var titleLines: Int = 3

    private var hasThumb: Bool { result.rawThumbnailURLString != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    NewsBadge(result: result, compact: true)
                    FaviconView(host: result.displayHost, size: 14)
                    Text(result.newsSourceName)
                        .scaledFont(size: 12)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                    if let rel = result.newsRelativeString {
                        Text("·").foregroundStyle(Brand.textTertiary)
                        Text(rel)
                            .font(.system(size: 12, weight: result.newsFreshness == .live ? .semibold : .regular))
                            .foregroundStyle(result.newsTimeColor())
                            .lineLimit(1)
                    }
                }
                Text(result.title)
                    .scaledFont(size: 15.5, weight: .medium)
                    .foregroundStyle(Brand.text)
                    .lineLimit(titleLines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasThumb {
                Spacer(minLength: 8)
                NewsThumbView(result: result, requestWidth: 260, requestHeight: 200)
                    .frame(width: 96, height: 72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One story in a topic section — `NewsRowContent` wrapped in a tap + context menu for the home feed.
struct HomeNewsRow: View {
    let result: SearXNGResult
    let onOpen: (SearXNGResult) -> Void

    var body: some View {
        Button { onOpen(result) } label: {
            NewsRowContent(result: result)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .contextMenu { NewsContextMenu(result: result) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title), \(result.newsSourceName)")
    }
}

// MARK: - Shared context menu

private struct NewsContextMenu: View {
    let result: SearXNGResult

    var body: some View {
        if let url = URL(string: result.url) {
            Button { UIPasteboard.general.string = result.url } label: {
                Label(L("Copy Link"), systemImage: "doc.on.doc")
            }
            ShareLink(item: url) { Label(L("Share…"), systemImage: "square.and.arrow.up") }
        }
    }
}
