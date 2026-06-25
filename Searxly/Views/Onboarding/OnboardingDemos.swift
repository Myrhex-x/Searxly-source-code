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

    private let query = "is my search actually private?"
    private let engines = ["Brave", "Wikipedia", "DuckDuckGo", "Qwant", "Startpage"]
    private struct Result { let title: String; let host: String; let snippet: String }
    private let results = [
        Result(title: "Searxly — private search, on your Mac", host: "searxly.app",
               snippet: "Queries are answered by a local SearXNG engine. Nothing is ever sent to a Searxly server."),
        Result(title: "How SearXNG keeps you anonymous", host: "docs.searxng.org",
               snippet: "Results are aggregated locally from dozens of sources, then stripped of trackers and ads."),
        Result(title: "Why local search beats incognito mode", host: "searxly.app/blog",
               snippet: "Private mode still talks to a search company. Local search doesn't talk to anyone.")
    ]

    private let cycle: Double = 10.0

    var body: some View {
        OnboardingDemoFrame(caption: "searxly · private search", minHeight: 296) {
            if reduceMotion {
                content(phase: 0.72)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    let phase = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    content(phase: phase)
                }
            }
        }
    }

    @ViewBuilder
    private func content(phase: Double) -> some View {
        let typed = typedCount(phase: phase)
        let showCaret = phase < 0.32 && (reduceMotion || sin(phase * cycle * 6) > 0)
        let outro = reduceMotion ? 1 : (1 - demoRamp(phase, start: 0.93, dur: 0.07))

        VStack(alignment: .leading, spacing: 14) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 1) {
                    Text(String(query.prefix(typed)))
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.primary)
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
            .background(
                Capsule(style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.07))
                    .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.18), lineWidth: 1))
            )

            // Engines aggregating
            HStack(spacing: 6) {
                ForEach(Array(engines.enumerated()), id: \.offset) { i, name in
                    let lit = reduceMotion ? 1 : demoRamp(phase, start: 0.30 + Double(i) * 0.025, dur: 0.05)
                    Text(name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(lit > 0.5 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.04 + 0.08 * lit))
                                .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.06 + 0.1 * lit), lineWidth: 1))
                        )
                }
                Spacer(minLength: 0)
            }
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.28, dur: 0.06))

            // Results meta
            Text("About 48,200 results · 0.02s · answered locally")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.42, dur: 0.1))

            // Results
            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                    let appear = reduceMotion ? 1 : demoRamp(phase, start: 0.44 + Double(i) * 0.08, dur: 0.14)
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
            .opacity(reduceMotion ? 1 : demoRamp(phase, start: 0.66, dur: 0.14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(outro)
    }

    private func typedCount(phase: Double) -> Int {
        if reduceMotion { return query.count }
        let p = demoClamp((phase - 0.03) / 0.24)
        return Int((p * Double(query.count)).rounded())
    }

    private func resultRow(_ r: Result) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.12))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "globe").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(r.host).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                Text(r.snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
            if reduceMotion {
                content(scan: 1.2, pct: 1, footer: 1, outro: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
                    let phase = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
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
        OnboardingDemoFrame(caption: "vpn · wireguard", minHeight: 296) {
            if reduceMotion {
                content(connected: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
                    let phase = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    let connected = demoRamp(phase, start: 0.18, dur: 0.16) * (1 - demoRamp(phase, start: 0.88, dur: 0.08))
                    content(connected: connected)
                }
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

            // Server location
            HStack(spacing: 11) {
                Circle().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "globe.europe.africa.fill").font(.system(size: 16)).foregroundStyle(.primary))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Amsterdam · Netherlands").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    Text("WireGuard · 12 ms").font(.system(size: 10.5)).foregroundStyle(.tertiary)
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
                stat("WireGuard", "Protocol")
                stat("ChaCha20", "Cipher")
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
