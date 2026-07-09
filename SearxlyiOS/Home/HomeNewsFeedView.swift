//
//  HomeNewsFeedView.swift
//  SearxlyIOS
//
//  The scroll-down news feed under the start-page hero: a "Latest" header with a refresh control, the
//  top-story banner, then a topic section per subject. Lazy — each section loads as it scrolls in — and
//  gently auto-refreshes while the home is on screen (the task is cancelled the moment it leaves). Lives
//  inside the home ScrollView; the hero above it is what you see first, this is what you scroll into.
//

import SwiftUI

struct HomeNewsFeedView: View {
    var feed = HomeNewsFeed.shared
    let onOpenStory: (SearXNGResult) -> Void
    let onSeeAll: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            header

            if let top = feed.topStory {
                HomeTopStoryHero(cluster: top, onOpen: onOpenStory)
                    .transition(.opacity)
            } else if feed.topStoryLoading {
                heroPlaceholder
            }

            ForEach(feed.visibleTopics) { topic in
                HomeTopicSection(topic: topic, feed: feed, onOpen: onOpenStory, onSeeAll: onSeeAll)
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 40)
        .animation(.easeOut(duration: 0.3), value: feed.topStory?.id)
        .task {
            // Gentle auto-refresh while the home is visible. Cancelled on disappear (the whole home
            // subtree goes away when the tab leaves .home), so it never runs in the background.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(HomeNewsFeed.autoRefreshInterval))
                if Task.isCancelled { break }
                feed.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Latest"))
                .scaledFont(size: 13, weight: .semibold)
                .tracking(1.2)
                .foregroundStyle(Brand.textSecondary)
            Rectangle().fill(Brand.hairline).frame(height: 0.5)
            if feed.isRefreshing {
                ProgressView().controlSize(.mini).tint(Brand.textTertiary)
            } else {
                Button { feed.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Brand.textTertiary)
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Refresh news"))
            }
        }
        .padding(.top, 2)
    }

    private var heroPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Brand.surface)
                .frame(height: 210)
            RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(width: 110, height: 11)
            RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(height: 20)
            RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(width: 220, height: 20)
        }
        .redacted(reason: .placeholder)
    }

    private var footer: some View {
        VStack(spacing: 5) {
            Text(L("Headlines from your search instance."))
                .scaledFont(size: 11.5)
                .foregroundStyle(Brand.textTertiary)
            Text(L("Kept in memory only — never saved, off in private tabs."))
                .scaledFont(size: 11)
                .foregroundStyle(Brand.textTertiary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
}
