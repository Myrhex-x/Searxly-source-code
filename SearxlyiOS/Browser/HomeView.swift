//
//  HomeView.swift
//  SearxlyiOS
//
//  The Searxly start page: dark, with the shared macOS "SEARXLY" wordmark centered. No search field
//  here — searching happens from the Safari-style bottom bar.
//

import SwiftUI

struct HomeView: View {
    /// Safari start-page gesture: pulling down on the page focuses the search field.
    var onPullDown: (() -> Void)? = nil
    /// Swipe up anywhere on the start page → tab overview (mirrors the toolbar swipe-up).
    var onSwipeUp: (() -> Void)? = nil
    /// Tapping a favorite (bookmark) chip loads it in this tab.
    var onOpenFavorite: ((URL) -> Void)? = nil

    private var shields = ShieldSettings.shared
    private var library = LibraryStore.shared

    var body: some View {
        ZStack {
            AdaptiveChrome.canvasDark.ignoresSafeArea()

            GeometryReader { geo in
                let size = logoSize(forWidth: geo.size.width)
                ZStack {
                    glow(logoSize: size)
                    SearxlyLogo(size: size, style: .hero, animated: true, showTagline: false)

                    // Favorites (top bookmarks) + the quiet lifetime privacy stat, docked low.
                    VStack(spacing: 22) {
                        Spacer()
                        if !library.bookmarks.isEmpty {
                            favoritesRow
                        }
                        if shields.lifetimeTrackersBlocked > 0 {
                            HStack(spacing: 5) {
                                Image(systemName: "shield.fill")
                                    .font(.system(size: 10, weight: .medium))
                                Text("\(shields.lifetimeTrackersBlocked.formatted()) \(L("trackers blocked"))")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                    .padding(.bottom, 26)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        // The start page is always a dark hero — force the subtree dark so the wordmark renders the
        // bright-white, glowing treatment regardless of the phone's light/dark setting.
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.height > 55, abs(value.translation.width) < 70 {
                        onPullDown?()
                    } else if value.translation.height < -55, abs(value.translation.width) < 70 {
                        Haptics.tick()
                        onSwipeUp?()
                    }
                }
        )
    }

    /// Quick access to the first few bookmarks — favicon chips with tiny labels, Safari start-page
    /// style but kept whisper-quiet under the hero (cache-only icons; this page fetches nothing).
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
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .frame(width: 58)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Favorite: \(bookmark.title)")
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
