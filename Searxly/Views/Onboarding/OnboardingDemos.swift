//
//  OnboardingDemos.swift
//  Searxly
//
//  "Show, don't tell" — large, auto-playing, fully non-interactive mock UIs that present
//  each feature in action. Every demo loops on a timeline, ignores hit-testing, stays
//  monochrome (per brand), and falls back to a static end-state under Reduce Motion.
//

import SwiftUI

private func demoClamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
    min(max(x, lo), hi)
}

/// Eased 0→1 ramp starting at `start`, lasting `dur`, within a normalized phase.
private func demoRamp(_ phase: Double, start: Double, dur: Double) -> Double {
    let p = demoClamp((phase - start) / dur)
    return p * p * (3 - 2 * p) // smoothstep
}

// MARK: - Appear-anchored loop driver

/// Drives a looping demo from a normalized phase (0→1) that **resets to 0 every time the view
/// appears**, so each presentation plays its intro from the very beginning the moment the user
/// lands on the step — never caught mid-cycle.
///
/// (The old demos derived phase from `Date.timeIntervalSinceReferenceDate`, i.e. the global wall
/// clock, so arriving on a step showed the animation already half-played — the "pre-loaded" look.)
/// Under Reduce Motion it renders a single static frame at `staticPhase`.
struct OnboardingLoopPhase<Content: View>: View {
    let cycle: Double
    var staticPhase: Double = 1.0
    var fps: Double = 24
    @ViewBuilder var content: (_ phase: Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        Group {
            if reduceMotion {
                content(staticPhase)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / fps)) { tl in
                    let elapsed = max(0, tl.date.timeIntervalSince(start))
                    content(elapsed.truncatingRemainder(dividingBy: cycle) / cycle)
                }
            }
        }
        // Re-anchor to the moment the demo becomes visible (after the step's slide-in), so the
        // intro is synced to the user's arrival rather than to whenever the view was first built.
        .onAppear { start = Date() }
    }
}

// MARK: - Demo frame (the "window" each presentation plays inside)

struct OnboardingDemoFrame<Content: View>: View {
    var caption: String = "Live preview"
    var minHeight: CGFloat = 300
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled

    var body: some View {
        VStack(spacing: 0) {
            // Window chrome
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(AdaptiveChrome.fill(colorScheme, dark: 0.18))
                        .frame(width: 9, height: 9)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.75 : 0.45))
                        .frame(width: 6, height: 6)
                    Text(caption.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Color.clear.frame(width: 39, height: 1)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(AdaptiveChrome.fill(colorScheme, dark: 0.04))

            Rectangle()
                .fill(AdaptiveChrome.divider(colorScheme))
                .frame(height: 1)

            content
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled).opacity(colorScheme == .dark ? 0.55 : 0.6))
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            AdaptiveChrome.border(colorScheme, dark: 0.22),
                            AdaptiveChrome.border(colorScheme, dark: 0.06)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: AdaptiveChrome.shadow(colorScheme, darkOpacity: 0.45), radius: 30, y: 14)
        .allowsHitTesting(false)
    }
}

// MARK: - Search demo

struct OnboardingSearchDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let query = "how do I keep my searches private?"
    // The engines Searxly's bundled SearXNG actually queries (the lean general-web set:
    // google + bing + duckduckgo + mojeek + wikipedia; brave/startpage were dropped as dead).
    private let engines = ["Google", "Bing", "DuckDuckGo", "Mojeek", "Wikipedia"]
    private struct Result { let title: String; let host: String; let snippet: String }
    private let results = [
        Result(title: "Private search, answered on your Mac — Searxly", host: "searxly.app",
               snippet: "Your query is answered by a SearXNG engine on 127.0.0.1. It never reaches a Searxly server, because there isn't one."),
        Result(title: "How metasearch keeps you anonymous", host: "docs.searxng.org",
               snippet: "Results are merged locally from many engines, then stripped of trackers, ads and profiling."),
        Result(title: "Incognito mode isn't private search", host: "searxly.app/blog",
               snippet: "A private window still sends every keystroke to a search company. Local search talks to no one about you.")
    ]

    private let cycle: Double = 9.5

    var body: some View {
        OnboardingDemoFrame(caption: "searxly · 127.0.0.1", minHeight: 312) {
            OnboardingLoopPhase(cycle: cycle, staticPhase: 0.85) { phase in
                content(phase: phase)
            }
        }
    }

    @ViewBuilder
    private func content(phase: Double) -> some View {
        let typed = typedCount(phase: phase)
        // Blinking caret only while typing.
        let showCaret = phase > 0.02 && phase < 0.30 && (reduceMotion || sin(phase * cycle * 6.5) > 0)
        let searching = phase >= 0.28 && phase < 0.46
        let outro = reduceMotion ? 1 : (1 - demoRamp(phase, start: 0.94, dur: 0.06))

        VStack(alignment: .leading, spacing: 13) {
            // Search bar with a thin "querying" progress sweep underneath.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 1) {
                        Text(String(query.prefix(typed)))
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if showCaret {
                            Capsule().fill(Color.primary).frame(width: 1.8, height: 16)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        Text("127.0.0.1").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(
                Capsule(style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.07))
                    .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: searching ? 0.28 : 0.18), lineWidth: 1))
            )

            // Engines — names brighten in sequence as each source returns. Rendered inline
            // (no boxes) so the differing name lengths never read as mismatched pills.
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                ForEach(Array(engines.enumerated()), id: \.offset) { i, name in
                    let lit = reduceMotion ? 1 : demoRamp(phase, start: 0.30 + Double(i) * 0.03, dur: 0.06)
                    if i > 0 {
                        Text("·").font(.system(size: 10, weight: .bold)).foregroundStyle(.quaternary)
                    }
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lit > 0.5 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                Spacer(minLength: 0)
            }
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.28, dur: 0.06))

            // Results meta
            Text("Results merged on this Mac · nothing logged")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.44, dur: 0.1))

            // Results
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                    let appear = reduceMotion ? 1 : demoRamp(phase, start: 0.48 + Double(i) * 0.08, dur: 0.14)
                    resultRow(r).opacity(appear).offset(y: (1 - appear) * 10)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 11, weight: .bold))
                Text("No query left this Mac · zero trackers")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.70, dur: 0.14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(outro)
    }

    private func typedCount(phase: Double) -> Int {
        if reduceMotion { return query.count }
        let p = demoClamp((phase - 0.03) / 0.22)
        return Int((p * Double(query.count)).rounded())
    }

    private func resultRow(_ r: Result) -> some View {
        HStack(alignment: .top, spacing: 11) {
            // Favicon-style tile (monogram of the host).
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.12))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(r.host.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary)
                    Text(r.host).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
                Text(r.snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - News demo

/// An auto-playing live-news feed: topic chips light up, then stories drop in newest-first with a red
/// LIVE badge on the freshest — all "fetched through your private SearXNG". Monochrome per brand, with
/// the one red accent the news surface actually uses.
struct OnboardingNewsDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let topics = ["World", "War", "Tech", "Business", "Science"]
    private struct Story { let source: String; let time: String; let title: String; let live: Bool }
    private let stories = [
        Story(source: "Reuters",   time: "4m ago",  title: "Ceasefire talks resume as envoys meet overnight", live: true),
        Story(source: "Bloomberg", time: "26m ago", title: "Central banks signal a shift as inflation cools", live: false),
        Story(source: "The Verge", time: "1h ago",  title: "New on-device AI models land across the industry", live: false)
    ]

    private let cycle: Double = 9.0

    var body: some View {
        OnboardingDemoFrame(caption: "searxly · news · 127.0.0.1", minHeight: 312) {
            OnboardingLoopPhase(cycle: cycle, staticPhase: 0.85) { phase in
                content(phase: phase)
            }
        }
    }

    @ViewBuilder
    private func content(phase: Double) -> some View {
        let outro = reduceMotion ? 1 : (1 - demoRamp(phase, start: 0.94, dur: 0.06))

        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "newspaper.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text("Live news").font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    Text("127.0.0.1").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(.tertiary)
            }

            // Topic chips brighten in sequence.
            HStack(spacing: 6) {
                ForEach(Array(topics.enumerated()), id: \.offset) { i, name in
                    let lit = reduceMotion ? 1 : demoRamp(phase, start: 0.10 + Double(i) * 0.04, dur: 0.06)
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lit > 0.5 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.04 + 0.05 * lit))
                                .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08 + 0.10 * lit), lineWidth: 1))
                        )
                }
                Spacer(minLength: 0)
            }
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.08, dur: 0.06))

            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(stories.enumerated()), id: \.offset) { i, s in
                    let appear = reduceMotion ? 1 : demoRamp(phase, start: 0.34 + Double(i) * 0.10, dur: 0.14)
                    storyRow(s).opacity(appear).offset(y: (1 - appear) * 10)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 11, weight: .bold))
                Text("Fetched through your private SearXNG · no news site sees you")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.70, dur: 0.14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(outro)
    }

    private func storyRow(_ s: Story) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.12))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "photo").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if s.live {
                        HStack(spacing: 3) {
                            Circle().fill(Color.white).frame(width: 4, height: 4)
                            Text("LIVE").font(.system(size: 8.5, weight: .bold)).tracking(0.4).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(SERPDesign.liveRed, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(s.source).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Text("· \(s.time)")
                        .font(.system(size: 10.5, weight: s.live ? .semibold : .regular))
                        .foregroundStyle(s.live ? AnyShapeStyle(SERPDesign.liveRed) : AnyShapeStyle(.tertiary))
                }
                Text(s.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Encryption demo

struct OnboardingEncryptionDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Item { let icon: String; let label: String; let value: String }
    private let items = [
        Item(icon: "key.fill", label: "Passwords", value: "github · 14 saved"),
        Item(icon: "clock", label: "History", value: "1,204 entries"),
        Item(icon: "bookmark.fill", label: "Bookmarks", value: "37 sites"),
        Item(icon: "wallet.pass.fill", label: "Wallet keys", value: "seed phrase"),
        Item(icon: "magnifyingglass", label: "Search activity", value: "this session")
    ]

    private let cycle: Double = 8.0

    var body: some View {
        OnboardingDemoFrame(caption: "on-device vault", minHeight: 296) {
            OnboardingLoopPhase(cycle: cycle, staticPhase: 0.80) { phase in
                let scan = demoRamp(phase, start: 0.12, dur: 0.46) * 1.15
                let pct = demoRamp(phase, start: 0.12, dur: 0.48)
                let footer = demoRamp(phase, start: 0.62, dur: 0.12)
                // Fade the whole panel out at the loop boundary, then back in, so the
                // reset is never a visible snap.
                let outro = (1 - demoRamp(phase, start: 0.93, dur: 0.05)) * demoRamp(phase, start: 0.0, dur: 0.05)
                content(scan: scan, pct: pct, footer: footer, outro: outro)
            }
        }
    }

    @ViewBuilder
    private func content(scan: Double, pct: Double, footer: Double, outro: Double) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                // Big lock + encryption ring
                VStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(AdaptiveChrome.fill(colorScheme, dark: 0.08), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: pct)
                            .stroke(
                                LinearGradient(
                                    colors: colorScheme == .dark ? [.white, .white.opacity(0.7)] : [.primary, .primary.opacity(0.6)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .shadow(color: .white.opacity(colorScheme == .dark ? 0.35 : 0), radius: 7)
                        ZStack {
                            Image(systemName: "lock.open.fill").font(.system(size: 30)).opacity(1 - demoClamp((pct - 0.85) / 0.15))
                            Image(systemName: "lock.fill").font(.system(size: 30)).opacity(demoClamp((pct - 0.85) / 0.15))
                        }
                        .foregroundStyle(.primary)
                    }
                    .frame(width: 112, height: 112)

                    Text("\(Int((pct * 100).rounded()))%")
                        .font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(.primary)
                    Text("ENCRYPTING").font(.system(size: 8.5, weight: .bold)).tracking(1.6).foregroundStyle(.tertiary)
                }
                .frame(width: 130)

                // Data rows with a sweeping scan line
                VStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        let rowCenter = (Double(i) + 0.5) / Double(items.count)
                        row(item, locked: demoClamp((scan - rowCenter) / 0.09))
                    }
                }
                .frame(maxWidth: .infinity)
                // Scan line as an OVERLAY so its GeometryReader measures the rows WITHOUT
                // contributing to layout. As a ZStack sibling the greedy GeometryReader inflated
                // the rows' height while the scan was active, growing the card and making the whole
                // vault panel jump vertically each animation cycle (and leaving a stray line).
                .overlay {
                    if scan > 0.01 && scan < 1.14 && !reduceMotion {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Color.white.opacity(colorScheme == .dark ? 0.5 : 0.3), .clear],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .frame(height: 2)
                                .position(x: geo.size.width / 2, y: geo.size.height * CGFloat(min(scan, 1)))
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill").font(.system(size: 12, weight: .bold))
                Text("Sealed with AES-256 · keys held in this Mac's Keychain")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .opacity(footer)
        }
        .opacity(reduceMotion ? 1 : outro)
    }

    private func row(_ item: Item, locked: Double) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 20)
            Text(item.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Text(item.value).font(.system(size: 11)).foregroundStyle(.tertiary).opacity(1 - locked)
                Text(String(repeating: "•", count: 10)).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).opacity(locked)
            }
            Image(systemName: locked > 0.5 ? "lock.fill" : "lock.open")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(locked > 0.5 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 14)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.04 + 0.05 * locked))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08 + 0.12 * locked), lineWidth: 1))
        )
    }
}

// MARK: - Wallet demo

struct OnboardingWalletDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let spark: [Double] = [0.28, 0.40, 0.34, 0.52, 0.46, 0.63, 0.57, 0.72, 0.66, 0.82, 0.78, 0.90]
    private struct Token { let symbol: String; let name: String; let amount: String; let fiat: String }
    private let tokens = [
        Token(symbol: "ETH", name: "Ethereum", amount: "0.412", fiat: "$1,043.18"),
        Token(symbol: "USDC", name: "USD Coin", amount: "241.32", fiat: "$241.32")
    ]

    var body: some View {
        OnboardingDemoFrame(caption: "wallet · base", minHeight: 296) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    HStack(spacing: 7) {
                        Circle().fill(AdaptiveChrome.fill(colorScheme, dark: 0.25)).frame(width: 18, height: 18)
                            .overlay(Image(systemName: "diamond.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.primary))
                        Text("Base").font(.system(size: 13, weight: .bold)).foregroundStyle(.primary)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        Text("SELF-CUSTODY").font(.system(size: 9, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("TOTAL BALANCE").font(.system(size: 9.5, weight: .bold)).tracking(1.0).foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        OnboardingAnimatableNumber(
                            value: appeared || reduceMotion ? 1284.50 : 0,
                            decimals: 2, prefix: "$",
                            font: .system(size: 34, weight: .bold)
                        )
                        .foregroundStyle(.primary)
                        .animation(reduceMotion ? nil : .easeOut(duration: 1.2), value: appeared)

                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                            Text("2.4% today").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                // Sparkline
                GeometryReader { geo in
                    sparkPath(in: geo.size)
                        .trim(from: 0, to: appeared || reduceMotion ? 1 : 0)
                        .stroke(
                            LinearGradient(
                                colors: colorScheme == .dark ? [.white.opacity(0.45), .white] : [.primary.opacity(0.45), .primary],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                        )
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.4), value: appeared)
                }
                .frame(height: 46)

                // Token list
                VStack(spacing: 8) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in tokenRow(t) }
                }

                HStack(spacing: 10) {
                    Text("0x49A2…2976").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    pill("Receive", "arrow.down"); pill("Send", "arrow.up")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { appeared = true }
    }

    private func tokenRow(_ t: Token) -> some View {
        HStack(spacing: 11) {
            Circle().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10))
                .frame(width: 30, height: 30)
                .overlay(Text(String(t.symbol.prefix(1))).font(.system(size: 13, weight: .bold)).foregroundStyle(.primary))
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                Text("\(t.amount) \(t.symbol)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(t.fiat).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.04))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 1))
        )
    }

    private func sparkPath(in size: CGSize) -> Path {
        Path { p in
            guard spark.count > 1 else { return }
            let stepX = size.width / CGFloat(spark.count - 1)
            for (i, v) in spark.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * stepX, y: size.height * (1 - CGFloat(v)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func pill(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10))
                .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.16), lineWidth: 1))
        )
    }
}

// MARK: - VPN demo

struct OnboardingVPNDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cycle: Double = 8.5

    var body: some View {
        OnboardingDemoFrame(caption: "vpn · ipsec", minHeight: 296) {
            OnboardingLoopPhase(cycle: cycle, staticPhase: 0.5) { phase in
                let connected = demoRamp(phase, start: 0.18, dur: 0.16) * (1 - demoRamp(phase, start: 0.88, dur: 0.08))
                content(connected: connected)
            }
        }
    }

    @ViewBuilder
    private func content(connected: Double) -> some View {
        let on = connected > 0.5
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(on ? "Protected" : "Exposed")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.primary)
                    Text(on ? "Traffic encrypted · IP hidden" : "Your traffic is visible")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                toggle(on: connected)
            }

            // Server — Searxly's own exit node (matches the live VPN pill).
            HStack(spacing: 11) {
                Circle().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "bolt.shield.fill").font(.system(size: 16)).foregroundStyle(.primary))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Searxly node").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    Text("199.217.99.103 · encrypted").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.primary).opacity(connected)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.09), lineWidth: 1))
            )

            OnboardingTunnelStrip().opacity(0.4 + 0.6 * connected)

            HStack {
                Text("PUBLIC IP").font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(.tertiary)
                Spacer()
                ZStack(alignment: .trailing) {
                    Text("203.0.113.42 · Paris, FR")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary).opacity(1 - connected)
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .bold))
                        Text("Hidden").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary).opacity(connected)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.09), lineWidth: 1))
            )

            HStack(spacing: 16) {
                stat("IPSec", "Protocol")
                stat("AES-256", "Cipher")
                stat("0", "Logs kept")
            }
            .opacity(0.5 + 0.5 * connected)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.primary)
            Text(label.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(on: Double) -> some View {
        let knob = on > 0.5
        return ZStack(alignment: knob ? .trailing : .leading) {
            Capsule()
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.10 + 0.20 * on))
                .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.18), lineWidth: 1))
                .frame(width: 52, height: 30)
            Circle()
                .fill(knob ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AdaptiveChrome.fill(colorScheme, dark: 0.5)))
                .frame(width: 24, height: 24).padding(.horizontal, 3)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: 52, height: 30)
    }
}

// MARK: - Tor demo

/// A Tor-Browser-style vertical circuit that builds itself: Tor bootstraps, then the route
/// lights up hop-by-hop (this Mac → guard → middle → exit → the hidden service) as the
/// connector fills downward. Mirrors the real `TorCircuitView` — onion-only, IP hidden.
struct OnboardingTorDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Hop { let title: String; let sub: String; let icon: String; let endpoint: Bool; let mono: Bool }
    private let hops: [Hop] = [
        Hop(title: "This Mac", sub: "Your .onion tab", icon: "laptopcomputer", endpoint: true, mono: false),
        Hop(title: "Guard relay", sub: "Entry into Tor", icon: "shield.lefthalf.filled", endpoint: false, mono: false),
        Hop(title: "Middle relay", sub: "Bounced through Tor", icon: "point.3.connected.trianglepath.dotted", endpoint: false, mono: false),
        Hop(title: "Exit relay", sub: "Leaves toward the site", icon: "arrow.up.forward", endpoint: false, mono: false),
        Hop(title: "duskgytl…onion", sub: "Hidden service reached", icon: "globe", endpoint: true, mono: true)
    ]

    private let cycle: Double = 9.0

    var body: some View {
        OnboardingDemoFrame(caption: "tor · onion routing", minHeight: 300) {
            OnboardingLoopPhase(cycle: cycle, staticPhase: 0.80) { phase in
                content(phase: phase)
            }
        }
    }

    @ViewBuilder
    private func content(phase: Double) -> some View {
        let bootstrap = reduceMotion ? 1 : demoRamp(phase, start: 0.0, dur: 0.20)
        let pct = Int((bootstrap * 100).rounded())
        let connected = reduceMotion ? 1 : demoRamp(phase, start: 0.58, dur: 0.10)
        let outro = reduceMotion ? 1 : (1 - demoRamp(phase, start: 0.92, dur: 0.08))
        let isUp = connected > 0.5

        VStack(spacing: 14) {
            // Status header
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isUp ? "Connected to Tor" : (bootstrap < 0.98 ? "Bootstrapping Tor…" : "Building circuit…"))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                    Text(isUp ? "Your IP is hidden behind 3 relays" : "Reaching the Tor network")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if isUp {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .bold))
                        Text("IP hidden").font(.system(size: 11, weight: .semibold))
                    }.foregroundStyle(.primary)
                } else {
                    Text("\(pct)%").font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            // Vertical circuit
            VStack(spacing: 0) {
                ForEach(Array(hops.enumerated()), id: \.offset) { i, hop in
                    let lit = reduceMotion ? 1 : demoRamp(phase, start: 0.20 + Double(i) * 0.085, dur: 0.07)
                    let fill = reduceMotion ? 1 : demoRamp(phase, start: 0.20 + Double(i) * 0.085 + 0.05, dur: 0.06)
                    hopRow(hop, lit: lit, connectorFill: fill, isLast: i == hops.count - 1)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill").font(.system(size: 11, weight: .bold))
                Text("Only .onion tabs route through Tor · nothing else changes")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.66, dur: 0.14))
        }
        .opacity(outro)
    }

    private func hopRow(_ hop: Hop, lit: Double, connectorFill: Double, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            // Left rail: node + connector segment that fills downward as the circuit builds.
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06 + 0.10 * lit))
                        .overlay(Circle().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.10 + 0.22 * lit), lineWidth: 1))
                        .frame(width: 28, height: 28)
                        .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.26 * lit : 0), radius: 6 * lit)
                    Image(systemName: hop.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(lit > 0.5 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                if !isLast {
                    ZStack(alignment: .top) {
                        Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.06)).frame(width: 2.5, height: 22)
                        Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.9 : 0.7))
                            .frame(width: 2.5, height: 22 * connectorFill)
                    }
                }
            }

            // Right: labels
            VStack(alignment: .leading, spacing: 2) {
                Text(hop.title)
                    .font(.system(size: 12.5, weight: hop.endpoint ? .bold : .semibold, design: hop.mono ? .monospaced : .default))
                    .foregroundStyle(lit > 0.4 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(hop.sub)
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Searxly AI demo

/// An auto-playing Searxly AI chat: a question types in, the assistant "thinks", then streams a grounded
/// answer with private sources. Monochrome, non-interactive, replays from the start on appear.
struct OnboardingAIDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let question = "How do I browse without being tracked?"
    private let answer = "Use private tabs, block trackers, and route sensitive tabs through Tor — Searxly does all three by default, and your searches never leave your Mac."
    private let sources = ["searxly.app", "eff.org", "torproject.org"]

    private let cycle: Double = 11.0
    private var words: [String] { answer.split(separator: " ").map(String.init) }

    var body: some View {
        OnboardingDemoFrame(caption: "searxly ai · private cloud", minHeight: 250) {
            OnboardingLoopPhase(cycle: cycle, staticPhase: 0.86) { phase in
                content(phase: phase)
            }
        }
    }

    @ViewBuilder
    private func content(phase: Double) -> some View {
        let typed = typedCount(phase: phase)
        let asking = phase < 0.26
        let showCaret = asking && phase > 0.03 && (reduceMotion || sin(phase * cycle * 6.0) > 0)
        let thinking = phase >= 0.28 && phase < 0.42
        let answering = phase >= 0.42
        let reveal = reduceMotion ? 1 : demoRamp(phase, start: 0.42, dur: 0.40)
        let wordsShown = Int((reveal * Double(words.count)).rounded())
        let streamCaret = !reduceMotion && phase >= 0.42 && phase < 0.84 && sin(phase * cycle * 6.0) > 0
        let footerIn = reduceMotion ? 1 : demoRamp(phase, start: 0.74, dur: 0.12)
        let outro = reduceMotion ? 1 : (1 - demoRamp(phase, start: 0.93, dur: 0.06))

        VStack(alignment: .leading, spacing: 13) {
            // Header
            HStack(spacing: 9) {
                aiMark
                VStack(alignment: .leading, spacing: 1) {
                    Text("Searxly AI").font(.system(size: 13.5, weight: .bold)).foregroundStyle(.primary)
                    Text("Private cloud · grounded answers").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 9, weight: .bold))
                    Text("Wallet connected").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }

            Rectangle().fill(AdaptiveChrome.divider(colorScheme)).frame(height: 1)

            // User question (right-aligned bubble, types in)
            HStack {
                Spacer(minLength: 40)
                HStack(spacing: 1) {
                    Text(String(question.prefix(typed)))
                        .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                    if showCaret { Capsule().fill(Color.primary).frame(width: 1.8, height: 15) }
                }
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)))
            }

            // Assistant reply
            HStack(alignment: .top, spacing: 10) {
                aiMark
                Group {
                    if thinking {
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle().fill(Color.primary.opacity(0.55)).frame(width: 6, height: 6)
                                    .opacity(reduceMotion ? 0.6 : 0.3 + 0.6 * (0.5 + 0.5 * sin(phase * cycle * 5 + Double(i) * 0.9)))
                            }
                        }
                        .padding(.vertical, 6)
                    } else if answering {
                        (Text(words.prefix(wordsShown).joined(separator: " ")) + Text(streamCaret ? " ▍" : ""))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary.opacity(0.92))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                Spacer(minLength: 0)
            }

            // Sources (grounded)
            HStack(spacing: 6) {
                Text("SOURCES").font(.system(size: 8.5, weight: .bold)).tracking(1.0).foregroundStyle(.tertiary)
                ForEach(Array(sources.enumerated()), id: \.offset) { i, host in
                    sourceChip(host)
                        .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.64 + Double(i) * 0.04, dur: 0.08))
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                Text("Answered privately · grounded in your on-device search")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .opacity(footerIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(outro)
    }

    private var aiMark: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AdaptiveChrome.fill(colorScheme, dark: 0.12))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.16), lineWidth: 1))
    }

    private func sourceChip(_ host: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.14))
                .frame(width: 14, height: 14)
                .overlay(Text(String(host.prefix(1)).uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary))
            Text(host).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.05))
                .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.10), lineWidth: 1))
        )
    }

    private func typedCount(phase: Double) -> Int {
        if reduceMotion { return question.count }
        let p = demoClamp((phase - 0.04) / 0.20)
        return Int((p * Double(question.count)).rounded())
    }
}
