//
//  HomeView.swift
//  SearxlyIOS
//
//  Start page, kept deliberately quiet: a utility row (privacy tally · history · settings),
//  glass favorites, your recent searches, and the news feed scrolling in right below. No
//  wordmark, no second search field — the bottom address bar is THE search input (tap a
//  recent to re-run it; pull down to focus the bar, Safari-style). Private tabs center a
//  badge instead — no recents, no news.
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
    /// Pulling down past the top (Safari's start-page gesture) → focus the search field.
    var onPullToSearch: (() -> Void)? = nil
    /// Tapping a recent search re-runs it.
    var onRecentSearch: ((String) -> Void)? = nil
    /// The clock in the top row → the Library sheet, History tab.
    var onOpenHistory: (() -> Void)? = nil
    /// The gear in the top row → the Settings sheet.
    var onOpenSettings: (() -> Void)? = nil
    /// Private tabs never show the news feed (it fetches from the instance).
    var isPrivate: Bool = false

    private var shields = ShieldSettings.shared
    private var library = LibraryStore.shared
    private var feed = HomeNewsFeed.shared
    private var defaultBrowser = DefaultBrowser.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var heroRevealed = false
    /// One-shot latch for the pull-to-search overscroll — re-armed once the scroll settles back.
    @State private var pullFired = false

    // Explicit init: the `private var` observed stores below would otherwise make the *synthesized*
    // memberwise init private (and unreachable from BrowserView) under the release Swift compiler.
    init(onOpenFavorite: ((URL) -> Void)? = nil,
         onOpenFavoriteNewTab: ((URL) -> Void)? = nil,
         onOpenStory: ((SearXNGResult) -> Void)? = nil,
         onSeeAllNews: ((String) -> Void)? = nil,
         onPullToSearch: (() -> Void)? = nil,
         onRecentSearch: ((String) -> Void)? = nil,
         onOpenHistory: (() -> Void)? = nil,
         onOpenSettings: (() -> Void)? = nil,
         isPrivate: Bool = false) {
        self.onOpenFavorite = onOpenFavorite
        self.onOpenFavoriteNewTab = onOpenFavoriteNewTab
        self.onOpenStory = onOpenStory
        self.onSeeAllNews = onSeeAllNews
        self.onPullToSearch = onPullToSearch
        self.onRecentSearch = onRecentSearch
        self.onOpenHistory = onOpenHistory
        self.onOpenSettings = onOpenSettings
        self.isPrivate = isPrivate
    }

    /// The news feed shows only when enabled and this isn't a private tab.
    private var showsNews: Bool { shields.newsHomeFeed && !isPrivate }

    /// Near-black in dark, paper-white in light — the home respects the system appearance.
    private var homeCanvas: Color {
        AdaptiveChrome.dynamic(light: AdaptiveChrome.canvasLight, dark: AdaptiveChrome.canvasDark)
    }

    /// Bookmarks first; fall back to top sites so a fresh install still has something useful.
    private var dockSites: [HomeDockSite] {
        if !library.bookmarks.isEmpty {
            return library.bookmarks.prefix(6).map {
                HomeDockSite(id: $0.url, url: $0.url, title: $0.title, kind: .bookmark)
            }
        }
        return library.topSites(limit: 6).map {
            let host = URL(string: $0.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? $0.url
            let label = siteLabel(host: host)
            return HomeDockSite(id: $0.url, url: $0.url, title: $0.title.isEmpty ? label : $0.title, kind: .topSite)
        }
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if isPrivate {
                            // Private: a centered badge — no recents, no news, nothing recorded.
                            privateHome
                                .containerRelativeFrame(.vertical)
                        } else {
                            homeHeader
                                .padding(.bottom, showsNews ? 22 : 0)
                            if showsNews {
                                HomeNewsFeedView(
                                    onOpenStory: { onOpenStory?($0) },
                                    onSeeAll: { onSeeAllNews?($0) }
                                )
                                .id(Self.newsAnchor)
                            }
                        }
                    }
                }
                // Always bounces: the overscroll IS the pull-to-search gesture (Safari's start-page
                // pull), so a pure hero must still give a little instead of staying pinned.
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(.hidden)
                // Pull down past the threshold → tick + focus the search field. Latched until the
                // scroll settles back near rest so one pull fires exactly once.
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, offset in
                    if offset < -70 {
                        if !pullFired {
                            pullFired = true
                            Haptics.tick()
                            onPullToSearch?()
                        }
                    } else if offset >= -4 {
                        pullFired = false
                    }
                }
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
        .background {
            homeAmbient
                .ignoresSafeArea()
        }
        .task { if showsNews { feed.preload() } }
        .onAppear { revealHero() }
    }

    private static let newsAnchor = "searxly.news.feed"

    // MARK: - Ambient canvas

    /// Soft focal glow + restrained starfield on pure `#000` — same canvas as searxly.app.
    private var homeAmbient: some View {
        ZStack {
            // Always the true black canvas first (never a grey plate).
            homeCanvas

            if colorScheme == .dark {
                HomeStarfieldCanvas()
                    .opacity(0.40)
                    .allowsHitTesting(false)
            }

            // Soft vignette back to pure black so edges stay absolute.
            RadialGradient(
                colors: [.clear, homeCanvas.opacity(colorScheme == .dark ? 0.72 : 0.25)],
                center: .center,
                startRadius: 100,
                endRadius: 480
            )
            .allowsHitTesting(false)

            // Private tabs get a whisper of indigo so the mode is ambient, not just a bar tint.
            if isPrivate {
                RadialGradient(
                    colors: [
                        Color(red: 0.35, green: 0.28, blue: 0.65).opacity(colorScheme == .dark ? 0.14 : 0.08),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.40),
                    startRadius: 40,
                    endRadius: 380
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Home header (utility row · favorites · recents)

    private var homeHeader: some View {
        VStack(spacing: Brand.Space.lg) {
            topRow
            // Only ever on the normal start page, only after a few launches, only until dismissed
            // — and it never appears at all until Apple grants the browser entitlement, because
            // without it Searxly isn't listed in Settings ▸ Default Apps. See DefaultBrowser.
            if defaultBrowser.shouldShowCard {
                DefaultBrowserCard()
                    .padding(.horizontal, Brand.Space.lg)
                    .opacity(heroRevealed ? 1 : 0)
                    .transition(.opacity)
            }
            if !dockSites.isEmpty {
                favoritesRow
                    .opacity(heroRevealed ? 1 : 0)
                    .offset(y: heroRevealed ? 0 : 10)
            }
            if !library.recentSearches.isEmpty {
                recentSearchesSection
                    .opacity(heroRevealed ? 1 : 0)
                    .offset(y: heroRevealed ? 0 : 12)
            }
        }
        .padding(.top, Brand.Space.md)
    }

    /// Private tabs: a centered badge + one honest line, nothing else. No favorites, no recents,
    /// no news — a private surface never displays normal-mode browsing, and the emptiness is
    /// the point (Safari's private start page makes the same statement).
    private var privateHome: some View {
        VStack(spacing: 0) {
            topRow
                .padding(.top, Brand.Space.md)
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                privateBadge
                    .opacity(heroRevealed ? 1 : 0)
                Text(L("Pages you visit here aren't saved to history, and their cookies vanish when you leave Private Mode."))
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .opacity(heroRevealed ? 1 : 0)
            }
            .offset(y: -24)
            Spacer(minLength: 0)
        }
    }

    /// Privacy tally on the left; history + settings on the right. Private tabs drop the
    /// history shortcut — normal-mode history has no business one tap from a private surface.
    private var topRow: some View {
        HStack(spacing: 10) {
            lifetimeBlockedPill
            Spacer(minLength: 0)
            if !isPrivate {
                utilityButton(icon: "clock.arrow.circlepath", label: L("History")) { onOpenHistory?() }
            }
            utilityButton(icon: "gearshape.fill", label: L("Settings")) { onOpenSettings?() }
        }
        .opacity(heroRevealed ? 1 : 0)
        .offset(y: heroRevealed ? 0 : -6)
        .padding(.horizontal, Brand.Space.lg)
    }

    private func utilityButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Brand.text.opacity(0.06)))
                .overlay(Circle().strokeBorder(Brand.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Recent searches as quiet hairline rows — tap to re-run, long-press to remove one.
    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Recent"))
                .scaledFont(size: Brand.FontSize.micro, weight: .semibold)
                .tracking(1.4)
                .foregroundStyle(Brand.textTertiary)
                .padding(.bottom, 6)
            ForEach(Array(library.recentSearches.prefix(6).enumerated()), id: \.element) { i, term in
                if i > 0 {
                    Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 26)
                }
                Button {
                    Haptics.tick()
                    onRecentSearch?(term)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(Brand.textTertiary)
                            .frame(width: 16)
                        Text(term)
                            .scaledFont(size: 15)
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(Brand.textTertiary.opacity(0.7))
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        library.removeRecentSearch(term)
                    } label: {
                        Label(L("Remove"), systemImage: "xmark")
                    }
                }
                .accessibilityLabel("\(L("Recent search")): \(term)")
            }
        }
        .padding(.horizontal, Brand.Space.lg)
    }

    /// Compact privacy tally — pure black capsule, single symmetrical row (matches site `#000`).
    private var lifetimeBlockedPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "shield.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(shields.lifetimeTrackersBlocked.formatted())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(L("blocked"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Solid pitch black — not Liquid Glass (glass lifts the surface to grey).
        .background(Capsule().fill(Color.black))
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(shields.lifetimeTrackersBlocked.formatted()) \(L("ads & trackers blocked"))"
        )
    }

    private var privateBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .scaledFont(size: 12, weight: .semibold)
            Text(L("Private Mode"))
                .scaledFont(size: Brand.FontSize.caption, weight: .semibold)
                .tracking(0.6)
        }
        .foregroundStyle(Brand.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(Color(red: 0.35, green: 0.28, blue: 0.65).opacity(colorScheme == .dark ? 0.28 : 0.12)),
            in: .capsule
        )
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 0.5))
        .accessibilityLabel(L("Private Mode"))
    }

    /// Quick access chips — bookmarks when present, otherwise top sites.
    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(dockSites) { site in
                    let host = URL(string: site.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? site.url
                    Button {
                        if let url = URL(string: site.url) { onOpenFavorite?(url) }
                    } label: {
                        VStack(spacing: 7) {
                            FaviconView(host: host, size: 38)
                                .padding(8)
                                .glassEffect(
                                    .regular.tint(AdaptiveChrome.fill(colorScheme, dark: 0.06, light: 0.04)),
                                    in: .rect(cornerRadius: 16)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Brand.hairline, lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                                        radius: 10, y: 4)
                            Text(shortTitle(site.title, host: host))
                                .scaledFont(size: Brand.FontSize.micro, weight: .medium)
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(1)
                                .frame(width: 62)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(site.kind == .bookmark ? L("Favorite") : L("Top site")): \(site.title)")
                    .contextMenu {
                        if let url = URL(string: site.url) {
                            Button { onOpenFavoriteNewTab?(url) } label: {
                                Label(L("Open in New Tab"), systemImage: "plus.square.on.square")
                            }
                            Button { UIPasteboard.general.string = site.url } label: {
                                Label(L("Copy Link"), systemImage: "doc.on.doc")
                            }
                            if site.kind == .bookmark {
                                Divider()
                                Button(role: .destructive) { library.removeBookmark(url: site.url) } label: {
                                    Label(L("Remove"), systemImage: "bookmark.slash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Brand.Space.xl)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func shortTitle(_ title: String, host: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        if cleaned.count <= 14, !cleaned.contains("/") { return cleaned }
        return siteLabel(host: host)
    }

    private func siteLabel(host: String) -> String {
        let labels = host.split(separator: ".")
        let main = labels.count >= 2 ? String(labels[labels.count - 2]) : (labels.first.map(String.init) ?? host)
        return main.prefix(1).uppercased() + main.dropFirst()
    }

    private func revealHero() {
        guard !heroRevealed else { return }
        if reduceMotion {
            heroRevealed = true
            return
        }
        withAnimation(.spring(response: 0.72, dampingFraction: 0.86).delay(0.12)) {
            heroRevealed = true
        }
    }
}

// MARK: - Dock model

private struct HomeDockSite: Identifiable {
    enum Kind { case bookmark, topSite }
    let id: String
    let url: String
    let title: String
    let kind: Kind
}

// MARK: - Lightweight starfield (home-only, Canvas, dark mode)

/// Sparse drifting stars for the dark home hero. Canvas-only, no timers when reduce-motion is on.
private struct HomeStarfieldCanvas: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let phase: Double
        let speed: Double
    }

    private let stars: [Star] = {
        var rng = SeededGenerator(seed: 0x5EA2_17)
        // Fewer stars still reads as a field; cheaper per frame.
        return (0..<28).map { _ in
            Star(
                x: CGFloat.random(in: 0...1, using: &rng),
                y: CGFloat.random(in: 0...1, using: &rng),
                size: CGFloat.random(in: 0.6...1.8, using: &rng),
                phase: Double.random(in: 0...(2 * .pi), using: &rng),
                speed: Double.random(in: 0.25...0.7, using: &rng)
            )
        }
    }()

    var body: some View {
        if reduceMotion {
            Canvas { context, size in
                for star in stars {
                    let rect = CGRect(
                        x: star.x * size.width,
                        y: star.y * size.height,
                        width: star.size,
                        height: star.size
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.22 + star.size * 0.08)))
                }
            }
        } else {
            // ~8 fps is plenty for a whisper of twinkle; 20 fps kept the GPU awake on the home canvas.
            TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    for star in stars {
                        let twinkle = 0.18 + 0.22 * (0.5 + 0.5 * sin(t * star.speed + star.phase))
                        let driftY = CGFloat(sin(t * star.speed * 0.35 + star.phase)) * 3
                        let rect = CGRect(
                            x: star.x * size.width,
                            y: star.y * size.height + driftY,
                            width: star.size,
                            height: star.size
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(twinkle)))
                    }
                }
            }
        }
    }
}

/// Tiny deterministic RNG so the starfield is stable across launches (no flicker on reappear).
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
