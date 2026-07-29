//
//  OnboardingFilmActs.swift
//  SearxlyiOS
//
//  The six acts of the onboarding film. Each act is a self-contained scene that stages its own
//  micro-animation through a cancellation-safe `.task` timeline — leaving the act cancels the
//  task, re-entering replays the scene. `live == false` (Reduce Motion / VoiceOver) renders the
//  final frame of every scene immediately. Acts 0–4 take an `onAdvance` closure purely for the
//  VoiceOver default action (double-tap = continue) — sighted navigation is the film's tap layer.
//

import SwiftUI

// MARK: - Shared type & chips

extension View {
    /// Film-beat reveal: rises and fades in once `on` flips (animate the flip at the call site).
    func filmReveal(_ on: Bool, rise: CGFloat = 12) -> some View {
        self
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : rise)
    }
}

private struct ActKicker: View {
    let index: Int
    let label: String

    var body: some View {
        Text("\(String(format: "%02d", index)) · \(label.uppercased())")
            .font(.system(size: 11, weight: .semibold))
            .tracking(3)
            .foregroundStyle(Color.white.opacity(0.4))
    }
}

private struct ActTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy))
            .tracking(-0.3)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }
}

private struct ActBody: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .frame(maxWidth: 320)
    }
}

private struct FilmChip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// VoiceOver contract shared by the scenery acts: one element, label = the scene's message,
/// double-tap = continue.
private struct SceneAccessibility: ViewModifier {
    let label: String
    let onAdvance: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(L("Double-tap to continue")))
            .accessibilityAction { onAdvance() }
    }
}

// MARK: - Act 0 · Title card

struct TitleAct: View {
    let live: Bool
    var onAdvance: () -> Void = {}

    @State private var taglineIn = false
    @State private var captionIn = false
    /// Ken Burns push-in: the whole lockup drifts from 1.0 → 1.035 across the act.
    @State private var drift: CGFloat = 1

    var body: some View {
        VStack(spacing: 30) {
            // The hero wordmark runs its own entrance, glow, and shine — accent bar on for the
            // full title-card treatment.
            SearxlyLogo(
                size: 34,
                style: .hero,
                animated: live,
                showTagline: false,
                showAccentBar: true
            )

            VStack(spacing: 18) {
                Text(L("PRIVATE. YOURS."))
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(4.2)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .filmReveal(taglineIn, rise: 10)

                HStack(spacing: 12) {
                    rule(leading: true)
                    Text(L("A private browser for iPhone").uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(2.6)
                        .foregroundStyle(Color.white.opacity(0.38))
                        .fixedSize()
                    rule(leading: false)
                }
                .filmReveal(captionIn, rise: 8)
            }
        }
        .scaleEffect(drift)
        .frame(maxWidth: .infinity)
        .modifier(SceneAccessibility(
            label: "Searxly — \(L("A private browser for iPhone"))",
            onAdvance: onAdvance
        ))
        .task { await play() }
    }

    /// Credit-line rules flanking the caption, fading toward the outside.
    private func rule(leading: Bool) -> some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.3)],
            startPoint: leading ? .leading : .trailing,
            endPoint: leading ? .trailing : .leading
        )
        .frame(width: 34, height: 1)
    }

    private func play() async {
        guard live else {
            taglineIn = true
            captionIn = true
            return
        }
        withAnimation(.easeInOut(duration: 6)) { drift = 1.035 }
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut(duration: 0.9)) { taglineIn = true }
        try? await Task.sleep(for: .seconds(0.8))
        withAnimation(.easeOut(duration: 0.9)) { captionIn = true }
    }
}

// MARK: - Act 1 · Shields

struct ShieldsAct: View {
    let live: Bool
    var onAdvance: () -> Void = {}

    @State private var titleIn = false
    /// Trackers closing in on the center…
    @State private var dotsIn = false
    /// …until the shield answers and they scatter off-frame.
    @State private var blocked = false
    @State private var ring1Scale: CGFloat = 0.3
    @State private var ring1Opacity: Double = 0
    @State private var ring2Scale: CGFloat = 0.3
    @State private var ring2Opacity: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var glyphIn = false
    @State private var pillIn = false
    @State private var bodyIn = false
    @State private var count = 0

    private static let trackerCount = 12
    private static let blockedTotal = 2_847

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ActKicker(index: 1, label: L("Shields")).filmReveal(titleIn)
                ActTitle(L("Blocked before it loads")).filmReveal(titleIn)
            }

            stage
                .frame(height: 244)

            ActBody(L("Ads, trackers, and fingerprinting are stopped on this device, with filter lists that ship inside the app."))
                .filmReveal(bodyIn)
        }
        .frame(maxWidth: .infinity)
        .modifier(SceneAccessibility(
            label: "\(L("Blocked before it loads")). \(L("Ads, trackers, and fingerprinting are stopped on this device, with filter lists that ship inside the app."))",
            onAdvance: onAdvance
        ))
        .task { await play() }
    }

    // Deliberately unclipped: the shockwave and the scattering dots need to overrun the stage
    // frame — dots fade to zero faster than they travel, so nothing ever hits the text blocks.
    private var stage: some View {
        ZStack {
            // Center flash the instant the shield answers.
            Circle()
                .fill(Color.white)
                .frame(width: 90, height: 90)
                .blur(radius: 22)
                .opacity(flashOpacity)

            // Double shockwave.
            Circle()
                .strokeBorder(Color.white.opacity(ring1Opacity), lineWidth: 1.2)
                .frame(width: 190, height: 190)
                .scaleEffect(ring1Scale)
            Circle()
                .strokeBorder(Color.white.opacity(ring2Opacity), lineWidth: 0.8)
                .frame(width: 190, height: 190)
                .scaleEffect(ring2Scale)

            // Incoming trackers — jittered ring so the swarm doesn't read as geometry. The fade
            // (fast) and the travel (slower) are decoupled so the scatter dissolves mid-flight.
            ForEach(0..<Self.trackerCount, id: \.self) { i in
                let angle = Double(i) / Double(Self.trackerCount) * 2 * .pi + sin(Double(i) * 7) * 0.16
                let radius: CGFloat = (blocked ? 240 : (dotsIn ? 76 : 172)) + CGFloat(i % 5) * 5
                let size: CGFloat = [3.5, 5, 4, 3][i % 4]
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: size, height: size)
                    .opacity(blocked ? 0 : 1)
                    .animation(.easeIn(duration: 0.3).delay(Double(i) * 0.015), value: blocked)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                    .animation(
                        .spring(response: 1.6, dampingFraction: 0.92).delay(Double(i) * 0.07),
                        value: dotsIn
                    )
                    .animation(.easeOut(duration: 0.6).delay(Double(i) * 0.015), value: blocked)
            }

            // The shield itself.
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 76, height: 76)
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    .frame(width: 76, height: 76)
                Image(systemName: "shield.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .scaleEffect(glyphIn ? 1 : 0.6)
            .opacity(glyphIn ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            // Counter pill — same language as the real home pill.
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(count.formatted())
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(L("blocked"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .filmReveal(pillIn)
        }
    }

    private func play() async {
        guard live else {
            titleIn = true
            dotsIn = true
            blocked = true
            glyphIn = true
            pillIn = true
            bodyIn = true
            count = Self.blockedTotal
            return
        }
        withAnimation(.easeOut(duration: 0.5)) { titleIn = true }
        dotsIn = true  // per-dot .animation handles the staggered drift inward
        try? await Task.sleep(for: .seconds(2.1))

        // The shield answers: flash, double shockwave, scatter.
        Haptics.tap()
        flashOpacity = 0.5
        withAnimation(.easeOut(duration: 0.5)) { flashOpacity = 0 }
        ring1Scale = 0.3
        ring1Opacity = 0.7
        withAnimation(.easeOut(duration: 0.7)) {
            ring1Scale = 1.5
            ring1Opacity = 0
        }
        blocked = true  // per-dot .animation scatters + dissolves them
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.1)) { glyphIn = true }

        try? await Task.sleep(for: .milliseconds(120))
        ring2Scale = 0.3
        ring2Opacity = 0.5
        withAnimation(.easeOut(duration: 0.8)) {
            ring2Scale = 1.15
            ring2Opacity = 0
        }

        try? await Task.sleep(for: .seconds(0.45))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { pillIn = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.1)) { bodyIn = true }

        // Eased count-up.
        for step in 1...26 {
            try? await Task.sleep(for: .milliseconds(55))
            if Task.isCancelled { return }
            let t = Double(step) / 26
            withAnimation(.linear(duration: 0.05)) {
                count = Int(Double(Self.blockedTotal) * (1 - pow(1 - t, 3)))
            }
        }
        count = Self.blockedTotal
    }
}

// MARK: - Act 2 · Private search

struct SearchAct: View {
    let live: Bool
    var onAdvance: () -> Void = {}

    @State private var titleIn = false
    @State private var cardIn = false
    @State private var typed = ""
    @State private var resultsVisible = 0
    @State private var caret = false
    @State private var chipsIn = false
    @State private var bodyIn = false

    private static let query = "best private search"
    private static let results: [(String, String)] = [
        ("What is a private search engine?", "searxly.app"),
        ("SearXNG — open-source metasearch", "docs.searxng.org"),
        ("How tracking-free search works", "wikipedia.org"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ActKicker(index: 2, label: L("Private search")).filmReveal(titleIn)
                ActTitle(L("Search without a profile")).filmReveal(titleIn)
            }

            serpCard
                .filmReveal(cardIn, rise: 16)

            HStack(spacing: 8) {
                FilmChip(L("No profile"))
                FilmChip(L("No ads"))
                FilmChip(L("No telemetry"))
            }
            .filmReveal(chipsIn, rise: 8)

            ActBody(L("No accounts. No ads in results. No telemetry. Queries go through private search — not a surveillance engine."))
                .filmReveal(bodyIn)
        }
        .frame(maxWidth: .infinity)
        .modifier(SceneAccessibility(
            label: "\(L("Search without a profile")). \(L("No accounts. No ads in results. No telemetry. Queries go through private search — not a surveillance engine."))",
            onAdvance: onAdvance
        ))
        .task { await play() }
    }

    /// Live mini-SERP under a spotlight — the product itself, not an icon.
    private var serpCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                HStack(spacing: 1) {
                    if typed.isEmpty {
                        Text(L("Search or enter address"))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.22))
                    } else {
                        Text(typed)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if live, typed.count < Self.query.count {
                        Rectangle()
                            .fill(Color.white.opacity(caret ? 0.9 : 0.15))
                            .frame(width: 1.5, height: 16)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.28))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.06))

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.results.enumerated()), id: \.offset) { index, row in
                    resultRow(rank: index + 1, title: row.0, host: row.1)
                        .filmReveal(resultsVisible > index, rise: 8)
                    if index < Self.results.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .frame(minHeight: CGFloat(Self.results.count) * 56)
        }
        .background(
            // Spotlight pooling behind the card.
            Ellipse()
                .fill(Color.white.opacity(0.05))
                .blur(radius: 46)
                .padding(-30)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .frame(maxWidth: 340)
    }

    private func resultRow(rank: Int, title: String, host: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.22))
                .frame(width: 14, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                Text(verbatim: host)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func play() async {
        guard live else {
            titleIn = true
            cardIn = true
            typed = Self.query
            resultsVisible = Self.results.count
            chipsIn = true
            bodyIn = true
            return
        }
        withAnimation(.easeOut(duration: 0.5)) { titleIn = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.25)) { cardIn = true }
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { caret = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.5)) { bodyIn = true }

        try? await Task.sleep(for: .seconds(0.7))
        for i in 1...Self.query.count {
            try? await Task.sleep(for: .milliseconds(70))
            if Task.isCancelled { return }
            typed = String(Self.query.prefix(i))
        }

        try? await Task.sleep(for: .seconds(0.25))
        for i in 1...Self.results.count {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { resultsVisible = i }
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { chipsIn = true }
    }
}

// MARK: - Act 3 · Apple Intelligence

struct IntelligenceAct: View {
    let live: Bool
    var onAdvance: () -> Void = {}

    @State private var titleIn = false
    @State private var markIn = false
    /// Halo breathes and the mark floats — the "alive" beat of the film.
    @State private var haloPulse = false
    @State private var floatUp = false
    @State private var linesVisible = 0
    /// One shimmer sweep across the finished summary, like light across fresh ink.
    @State private var shimmerX: CGFloat = -220
    @State private var checkIn = false
    @State private var chipIn = false
    @State private var bodyIn = false

    private static let lineWidths: [CGFloat] = [248, 210, 148]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ActKicker(index: 3, label: L("Intelligence")).filmReveal(titleIn)
                ActTitle(L("Apple Intelligence")).filmReveal(titleIn)
            }

            VStack(spacing: 20) {
                // The official mark, floating free over a breathing rainbow halo.
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.4),
                                    Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.34),
                                    Color(red: 1.0, green: 0.45, blue: 0.70).opacity(0.36),
                                    Color(red: 1.0, green: 0.72, blue: 0.35).opacity(0.30),
                                    Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.4)
                                ],
                                center: .center
                            )
                        )
                        .frame(width: 104, height: 104)
                        .blur(radius: 26)
                        .scaleEffect(haloPulse ? 1.14 : 0.92)
                        .opacity(markIn ? 0.9 : 0)

                    AppleIntelligenceMark(size: 54)
                        .offset(y: floatUp ? -4 : 4)
                        .scaleEffect(markIn ? 1 : 0.7)
                        .opacity(markIn ? 1 : 0)
                }
                .frame(height: 116)

                // A page summary writing itself — header, three growing lines, a full stop.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        AppleIntelligenceMark(size: 12, monochrome: true)
                            .foregroundStyle(Color.white.opacity(0.5))
                        Text(L("Summary").uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.8)
                            .foregroundStyle(Color.white.opacity(0.42))
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .opacity(checkIn ? 1 : 0)
                            .scaleEffect(checkIn ? 1 : 0.5)
                    }

                    linesBlock
                        .overlay(
                            // The single shimmer pass, masked to the lines themselves.
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.4), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 90)
                            .offset(x: shimmerX)
                            .blendMode(.plusLighter)
                            .mask(linesBlock)
                        )
                }
                .padding(16)
                .frame(width: 292)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
                )
            }

            FilmChip(L("On-device AI"))
                .filmReveal(chipIn, rise: 8)

            ActBody(L("AI Overview, page summaries, and “ask about this page” run with Apple Intelligence on-device. The page never leaves your phone — which is why it works in private tabs."))
                .filmReveal(bodyIn)
        }
        .frame(maxWidth: .infinity)
        .modifier(SceneAccessibility(
            label: "\(L("Apple Intelligence")). \(L("AI Overview, page summaries, and “ask about this page” run with Apple Intelligence on-device. The page never leaves your phone — which is why it works in private tabs."))",
            onAdvance: onAdvance
        ))
        .task { await play() }
    }

    private var linesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<Self.lineWidths.count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: linesVisible > i ? Self.lineWidths[i] : 12, height: 8)
                    .opacity(linesVisible > i ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func play() async {
        guard live else {
            titleIn = true
            markIn = true
            linesVisible = Self.lineWidths.count
            checkIn = true
            chipIn = true
            bodyIn = true
            return
        }
        withAnimation(.easeOut(duration: 0.5)) { titleIn = true }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.75).delay(0.25)) { markIn = true }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { haloPulse = true }
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { floatUp = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.5)) { bodyIn = true }

        // The summary writes itself…
        try? await Task.sleep(for: .seconds(1.1))
        for i in 1...Self.lineWidths.count {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { linesVisible = i }
            try? await Task.sleep(for: .milliseconds(420))
            if Task.isCancelled { return }
        }
        // …catches the light…
        withAnimation(.easeInOut(duration: 0.9)) { shimmerX = 220 }
        try? await Task.sleep(for: .seconds(0.55))
        // …and signs off.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { checkIn = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.15)) { chipIn = true }
    }
}

// MARK: - Act 4 · Yours

struct YoursAct: View {
    let live: Bool
    var onAdvance: () -> Void = {}

    @State private var titleIn = false
    /// The phone outline draws itself in.
    @State private var drawn: CGFloat = 0
    @State private var rowsVisible = 0
    @State private var lockIn = false
    @State private var chipsIn = false
    @State private var bodyIn = false

    private static let rows: [(String, CGFloat)] = [
        ("bookmark.fill", 58),
        ("clock.arrow.circlepath", 44),
        ("key.fill", 50),
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ActKicker(index: 4, label: L("Yours")).filmReveal(titleIn)
                ActTitle(L("Yours alone")).filmReveal(titleIn)
            }

            stage
                .frame(height: 236)

            HStack(spacing: 8) {
                FilmChip(L("No accounts"))
                FilmChip(L("No tracking"))
            }
            .filmReveal(chipsIn, rise: 8)

            ActBody(L("Bookmarks and history stay encrypted on this device. Private tabs leave no trace. There is no Searxly account — and nothing to sell."))
                .filmReveal(bodyIn)
        }
        .frame(maxWidth: .infinity)
        .modifier(SceneAccessibility(
            label: "\(L("Yours alone")). \(L("Bookmarks and history stay encrypted on this device. Private tabs leave no trace. There is no Searxly account — and nothing to sell."))",
            onAdvance: onAdvance
        ))
        .task { await play() }
    }

    private var stage: some View {
        ZStack {
            // The device, drawing itself into existence.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .trim(from: 0, to: drawn)
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: 124, height: 208)

            // What lives inside: bookmarks, history, keys.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 8) {
                        Image(systemName: row.0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .frame(width: 14)
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: row.1, height: 6)
                    }
                    .filmReveal(rowsVisible > index, rise: 10)
                }
            }
            .offset(y: -26)

            // The lock closes over it all.
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: 44, height: 44)
                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                    .frame(width: 44, height: 44)
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .offset(y: 62)
            .scaleEffect(lockIn ? 1 : 0.5)
            .opacity(lockIn ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func play() async {
        guard live else {
            titleIn = true
            drawn = 1
            rowsVisible = Self.rows.count
            lockIn = true
            chipsIn = true
            bodyIn = true
            return
        }
        withAnimation(.easeOut(duration: 0.5)) { titleIn = true }
        withAnimation(.easeInOut(duration: 1.1).delay(0.2)) { drawn = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(0.5)) { bodyIn = true }

        try? await Task.sleep(for: .seconds(1.3))
        for i in 1...Self.rows.count {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { rowsVisible = i }
            try? await Task.sleep(for: .milliseconds(260))
            if Task.isCancelled { return }
        }

        try? await Task.sleep(for: .seconds(0.5))
        Haptics.tick()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { lockIn = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.25)) { chipsIn = true }
    }
}

// MARK: - Act 5 · Creed

struct FinaleAct: View {
    let live: Bool
    var onStart: () -> Void
    var onReplay: () -> Void

    @State private var line1 = false
    @State private var line2 = false
    @State private var subIn = false
    @State private var ctaIn = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                Text(L("Private."))
                    .font(.system(size: 46, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(.white)
                    .filmReveal(line1, rise: 20)
                Text(L("Yours."))
                    .font(.system(size: 46, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .filmReveal(line2, rise: 20)
            }

            Text(L("No accounts. No tracking. Just the web."))
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .filmReveal(subIn)

            VStack(spacing: 16) {
                Button(action: onStart) {
                    Text(L("Start browsing"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: 280)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(Color.white)
                                .shadow(color: .white.opacity(0.18), radius: 18)
                        )
                }
                .buttonStyle(FilmPressStyle())

                Button(action: onReplay) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("Watch again"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
            .filmReveal(ctaIn, rise: 14)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .task { await play() }
    }

    private func play() async {
        guard live else {
            line1 = true
            line2 = true
            subIn = true
            ctaIn = true
            return
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.15)) { line1 = true }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.45)) { line2 = true }
        withAnimation(.easeOut(duration: 0.7).delay(1.0)) { subIn = true }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(1.4)) { ctaIn = true }
    }
}
