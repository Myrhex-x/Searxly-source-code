//
//  HomeNewsSection.swift
//  Searxly
//
//  A topic block for the home news feed: a header (icon + name + "See all") over a responsive grid of
//  story cards. A grid — not a horizontal carousel — so vertical scrolling stays native-smooth (nested
//  horizontal scroll views fight the page scroll) and the cards fill the width symmetrically.
//

import SwiftUI
import AppKit

struct HomeTopicSection: View {
    let topic: HomeNewsFeed.Topic
    var feed: HomeNewsFeed
    let glassEnabled: Bool
    let instances: [SearXNGInstance]
    let onOpenStory: (SearXNGResult) -> Void
    let onSeeAll: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: .infinity), spacing: 16, alignment: .top)]

    var body: some View {
        // nil = not attempted yet (reserve height with a placeholder + trigger the load); [] = resolved
        // empty → collapse to nothing; [items] = show the grid.
        let resolved = feed.stories[topic.id]

        if resolved == nil || feed.loading.contains(topic.id) || (resolved?.isEmpty == false) {
            VStack(alignment: .leading, spacing: 13) {
                header
                if let stories = resolved, !stories.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(stories.prefix(8)) { result in
                            HomeNewsCard(result: result, glassEnabled: glassEnabled, onOpen: onOpenStory)
                        }
                    }
                    .transition(.opacity)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(0..<4, id: \.self) { _ in placeholderCard }
                    }
                }
            }
            .animation(.easeOut(duration: 0.28), value: resolved?.count ?? -1)
            .onAppear { feed.loadIfNeeded(topic, instances: instances) }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: topic.systemIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(Localization.string(topic.labelKey, defaultValue: topic.id.capitalized))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button {
                onSeeAll(topic.query)
            } label: {
                HStack(spacing: 3) {
                    Text(Localization.string("home_see_all", defaultValue: "See all"))
                        .font(.system(size: 12.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.28))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.22)).frame(width: 90, height: 10)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.22)).frame(height: 13)
        }
    }
}

/// The single most important story, shown as a large banner atop the news home.
struct HomeBreakingHero: View {
    @Environment(\.colorScheme) private var colorScheme
    let cluster: NewsCluster
    let glassEnabled: Bool
    let onOpen: (SearXNGResult) -> Void
    let onOpenInNewTab: (SearXNGResult) -> Void

    @State private var isHovering = false

    private var lead: SearXNGResult { cluster.lead }

    private var label: (text: String, dot: Bool) {
        if lead.isBreakingNews { return (Localization.string("news_badge_breaking", defaultValue: "BREAKING"), false) }
        if lead.newsFreshness == .live { return (Localization.string("news_badge_live", defaultValue: "LIVE"), true) }
        return (Localization.string("news_top_story", defaultValue: "TOP STORY"), false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { onOpen(lead) } label: {
                VStack(alignment: .leading, spacing: 13) {
                    CachedSearchThumbnail(
                        candidates: lead.newsThumbnailCandidates(width: 1280, height: 640),
                        referer: lead.url,
                        aspectRatio: 2.0 / 1.0,
                        fillFrameHeight: 300
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.10), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            if label.dot { PulsingLiveDot(size: 6, color: .white) }
                            Text(label.text)
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SERPDesign.liveRed, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(13)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 5) {
                            FaviconView(pageURL: lead.url, size: 14, cornerRadius: 3, loadRemote: true)
                            Text(lead.newsSourceName)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(12)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            FaviconView(pageURL: lead.url, size: 17, cornerRadius: 4, loadRemote: true)
                            Text(lead.newsSourceName)
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let rel = lead.newsRelativeString {
                                Text("·").foregroundStyle(.quaternary)
                                Text(rel)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(lead.newsTimeColor())
                            }
                        }
                        Text(lead.title)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(isHovering ? Color.primary.opacity(0.82) : Color.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if let snippet = lead.newsCleanSnippet, !snippet.isEmpty {
                            Text(snippet)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Color.primary.opacity(0.72))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
                if hovering { HoverLinkState.shared.enter(lead.url) } else { HoverLinkState.shared.leave(lead.url) }
            }
            .contextMenu {
                Button(Localization.string("search_result_open")) { onOpen(lead) }
                Button(Localization.string("search_result_open_new_tab")) { onOpenInNewTab(lead) }
                Button(Localization.string("search_result_copy_link")) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(lead.url, forType: .string)
                }
            }

            if cluster.hasFullCoverage {
                FullCoverageDisclosure(
                    others: cluster.others,
                    totalSources: cluster.sourceCount,
                    glassEnabled: glassEnabled,
                    onOpen: onOpen,
                    onOpenInNewTab: onOpenInNewTab
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct HomeNewsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let result: SearXNGResult
    let glassEnabled: Bool
    let onOpen: (SearXNGResult) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onOpen(result)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                CachedSearchThumbnail(
                    candidates: result.newsThumbnailCandidates(width: 600, height: 338),
                    referer: result.url,
                    aspectRatio: 16.0 / 9.0,
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.09), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    NewsBadge(result: result, compact: true)
                        .padding(8)
                }

                HStack(spacing: 6) {
                    FaviconView(pageURL: result.url, size: 15, cornerRadius: 3.5, loadRemote: true)
                    Text(result.newsSourceName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let rel = result.newsRelativeString {
                        Text("·").foregroundStyle(.quaternary)
                        Text(rel)
                            .font(.system(size: 12, weight: result.newsFreshness == .live ? .semibold : .regular))
                            .foregroundStyle(result.newsTimeColor())
                            .lineLimit(1)
                    }
                }

                Text(result.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isHovering ? Color.primary.opacity(0.8) : Color.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { HoverLinkState.shared.enter(result.url) } else { HoverLinkState.shared.leave(result.url) }
        }
        .contextMenu {
            Button(Localization.string("search_result_open")) { onOpen(result) }
            Button(Localization.string("search_result_copy_link")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.url, forType: .string)
            }
        }
        .accessibilityLabel("\(result.title), \(result.newsSourceName)")
    }
}
