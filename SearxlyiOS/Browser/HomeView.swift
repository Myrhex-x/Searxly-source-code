//
//  HomeView.swift
//  SearxlyiOS
//
//  The Searxly start page: a dark, glowing "SEARXLY" hero that fills the ENTIRE first screen — the news
//  feed lives strictly below the fold, revealed only by scrolling (a "Scroll for news" cue points the
//  way). The hero is sized with containerRelativeFrame(.vertical) so it's always exactly one screen tall,
//  which keeps the feed from ever peeking up into the hero. Always a dark hero regardless of the system
//  appearance; the feed below stays dark to match. No search field — searching is the bottom bar's job.
//

import SwiftUI
import UIKit

struct HomeView: View {
    /// Tapping a favorite (bookmark) chip loads it in this tab.
    var onOpenFavorite: ((URL) -> Void)? = nil
    /// Long-press → open a favorite in a new tab.
    var onOpenFavoriteNewTab: ((URL) -> Void)? = nil
    /// Opening a news story from the feed.
    var onOpenStory: ((SearXNGResult) -> Void)? = nil
    /// "See all" on a topic → run that topic's news search.
    var onSeeAllNews: ((String) -> Void)? = nil
    /// Private tabs never show the news feed (it fetches from the instance).
    var isPrivate: Bool = false

    private var shields = ShieldSettings.shared
    private var library = LibraryStore.shared
    private var feed = HomeNewsFeed.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cueBob = false

    /// The news feed shows only when enabled and this isn't a private tab.
    private var showsNews: Bool { shields.newsHomeFeed && !isPrivate }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        heroSection
                            // Exactly one screen tall — the canonical way to keep the feed below the fold.
                            .containerRelativeFrame(.vertical)
                        if showsNews {
                            // The scroll content runs UNDER the translucent floating bar, but the hero
                            // above is measured at the *visible* height — so the feed would otherwise
                            // land in that under-bar gap and peek. Push it down by the bottom inset so
                            // it sits fully below the fold, revealed only on scroll.
                            Color.clear
                                .frame(height: outer.safeAreaInsets.bottom)
                                .accessibilityHidden(true)
                            HomeNewsFeedView(
                                onOpenStory: { onOpenStory?($0) },
                                onSeeAll: { onSeeAllNews?($0) }
                            )
                            .id(Self.newsAnchor)
                        }
                    }
                }
                // Only scrolls/bounces when there's a feed below — a pure hero stays put.
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                #if DEBUG
                .onAppear {
                    // simctl can't scroll — this drives the real layout to the feed for headless screenshots.
                    if ProcessInfo.processInfo.environment["SEARXLY_DEMO_NEWS"] == "1", showsNews {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            withAnimation { proxy.scrollTo(Self.newsAnchor, anchor: .top) }
                        }
                    }
                }
                #endif
            }
        }
        .background(AdaptiveChrome.canvasDark.ignoresSafeArea())
        // The start page is always a dark hero — force the subtree dark so the wordmark renders the
        // bright-white, glowing treatment (and the feed matches) regardless of the phone's setting.
        .environment(\.colorScheme, .dark)
        .task { if showsNews { feed.preload() } }
    }

    private static let newsAnchor = "searxly.news.feed"

    // MARK: - Hero (first screen)

    private var heroSection: some View {
        GeometryReader { geo in
            let size = logoSize(forWidth: geo.size.width)
            let hasBottomCluster = !library.bookmarks.isEmpty || showsNews || shields.lifetimeTrackersBlocked > 0
            ZStack {
                // Wordmark + halo, nudged just above center so the composition breathes above the
                // bottom cluster (dead-centered when there's nothing docked below, e.g. a private tab).
                ZStack {
                    glow(logoSize: size)
                    SearxlyLogo(size: size, style: .hero, animated: true, showTagline: false)
                }
                .offset(y: hasBottomCluster ? -geo.size.height * 0.055 : 0)

                VStack(spacing: 16) {
                    Spacer()
                    if !library.bookmarks.isEmpty {
                        favoritesRow
                    }
                    if shields.lifetimeTrackersBlocked > 0 {
                        trackersStat
                    }
                    if showsNews {
                        scrollCue.padding(.top, 4)
                    }
                }
                .padding(.bottom, 30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The clear "there's more below" affordance the hero was missing: a quiet label + a gently
    /// bobbing chevron that invites the scroll to the news feed.
    private var scrollCue: some View {
        VStack(spacing: 6) {
            Text(L("Scroll for news"))
                .scaledFont(size: 11, weight: .semibold)
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.42))
            Image(systemName: "chevron.down")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(.white.opacity(0.42))
                .offset(y: cueBob ? 5 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { cueBob = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Scroll down for news"))
    }

    private var trackersStat: some View {
        HStack(spacing: 5) {
            Image(systemName: "shield.fill")
                .scaledFont(size: 10, weight: .medium)
            Text("\(shields.lifetimeTrackersBlocked.formatted()) \(L("trackers blocked"))")
                .scaledFont(size: 12.5, weight: .medium)
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.36))
    }

    /// Quick access to the first few bookmarks — favicon chips with tiny labels, Safari start-page
    /// style but kept whisper-quiet under the hero (cache-only icons; this page fetches no favicons).
    private var favoritesRow: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(library.bookmarks.prefix(5)) { bookmark in
                let host = URL(string: bookmark.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? bookmark.url
                Button {
                    if let url = URL(string: bookmark.url) { onOpenFavorite?(url) }
                } label: {
                    VStack(spacing: 6) {
                        FaviconView(host: host, size: 40)
                            .padding(7)
                            // Glass pods on the dark hero — the glow refracts through them.
                            .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 16))
                        Text(bookmark.title)
                            .scaledFont(size: 10.5, weight: .medium)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .frame(width: 58)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Favorite: \(bookmark.title)")
                .contextMenu {
                    if let url = URL(string: bookmark.url) {
                        Button { onOpenFavoriteNewTab?(url) } label: {
                            Label(L("Open in New Tab"), systemImage: "plus.square.on.square")
                        }
                        Button { UIPasteboard.general.string = bookmark.url } label: {
                            Label(L("Copy Link"), systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) { library.removeBookmark(url: bookmark.url) } label: {
                            Label(L("Remove"), systemImage: "bookmark.slash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// The wordmark lays out at a fixed natural width (≈ 7.74 × size), so we must scale it to the
    /// device or it overflows on narrower phones. Target ~72% of the width, clamped to a sane range.
    private func logoSize(forWidth width: CGFloat) -> CGFloat {
        let target = (width * 0.72 - 36) / 7.74
        return min(36, max(20, target))
    }

    /// A strong, soft "sunlight" halo behind the wordmark, sized relative to the logo so it scales
    /// with the device. Two stacked ellipses (wide bloom + bright core), screen-blended.
    private func glow(logoSize: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color.white)
                .frame(width: logoSize * 11, height: logoSize * 5)
                .blur(radius: 90)
                .opacity(0.16)
            Ellipse()
                .fill(Color.white)
                .frame(width: logoSize * 7, height: logoSize * 3.2)
                .blur(radius: 50)
                .opacity(0.26)
        }
        .offset(y: -8)
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}
