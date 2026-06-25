//
//  OnboardingVisuals.swift
//  Searxly
//
//  Cinematic, monochrome onboarding visuals — count-up stats, comparison charts,
//  a security gauge, pulsing feature glyphs, an encrypted-tunnel strip, and shooting
//  stars. Everything stays black & white (per brand); white is the hero, glow does
//  the lifting. All animations respect Reduce Motion.
//

import SwiftUI

// MARK: - Count-up number

/// An `Animatable` `Text` — SwiftUI re-renders `body` for every interpolated
/// `value`, so wrapping it in a `withAnimation` block produces a smooth count-up.
struct OnboardingAnimatableNumber: View, Animatable {
    var value: Double
    var decimals: Int = 0
    var prefix: String = ""
    var suffix: String = ""
    var font: Font

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(prefix)\(formatted)\(suffix)")
            .font(font)
            .monospacedDigit()
    }

    private var formatted: String {
        if decimals == 0 { return "\(Int(value.rounded()))" }
        return String(format: "%.\(decimals)f", value)
    }
}

/// A single hero statistic that counts up from zero on appear.
struct OnboardingStatChip: View {
    let target: Double
    var decimals: Int = 0
    var prefix: String = ""
    var suffix: String = ""
    let caption: String
    var delay: Double = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            OnboardingAnimatableNumber(
                value: current,
                decimals: decimals,
                prefix: prefix,
                suffix: suffix,
                font: .system(size: 32, weight: .bold)
            )
            .foregroundStyle(.primary)

            Text(caption.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.07 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    AdaptiveChrome.border(colorScheme, dark: 0.18),
                                    AdaptiveChrome.border(colorScheme, dark: 0.05)
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
        )
        .onAppear {
            guard !reduceMotion else { current = target; return }
            withAnimation(.easeOut(duration: 1.05).delay(delay)) {
                current = target
            }
        }
    }
}

// MARK: - Comparison bar chart

/// A small horizontal bar chart used to make the privacy story instantly legible.
/// Bars grow on appear with a staggered spring; the emphasized bar (Searxly) reads
/// as a bright, glowing "near-zero" cap.
struct OnboardingBarChart: View {
    struct Bar: Identifiable {
        let id = UUID()
        let label: String
        let caption: String
        let value: Double       // 0...1
        var emphasized: Bool = false

        init(label: String, caption: String, value: Double, emphasized: Bool = false) {
            self.label = label
            self.caption = caption
            self.value = value
            self.emphasized = emphasized
        }
    }

    let bars: [Bar]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                row(bar, index: index)
            }
        }
        .onAppear {
            guard !reduceMotion else { animate = true; return }
            animate = true
        }
    }

    private func row(_ bar: Bar, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.label)
                    .font(.system(size: 12.5, weight: bar.emphasized ? .bold : .medium))
                    .foregroundStyle(bar.emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                Text(bar.caption)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(bar.emphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }

            GeometryReader { geo in
                let w = geo.size.width
                let filled = bar.emphasized ? max(14, w * 0.06) : max(0, w * bar.value)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06))

                    Capsule(style: .continuous)
                        .fill(barFill(bar))
                        .frame(width: animate ? filled : 0)
                        .shadow(
                            color: bar.emphasized
                                ? Color.white.opacity(colorScheme == .dark ? 0.45 : 0.0)
                                : .clear,
                            radius: 7
                        )
                        .animation(
                            reduceMotion ? nil
                                : .spring(response: 0.85, dampingFraction: 0.82)
                                    .delay(0.12 + Double(index) * 0.14),
                            value: animate
                        )

                    if bar.emphasized {
                        Text("0")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.primary)
                            .offset(x: filled + 8)
                            .opacity(animate ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.5 + Double(index) * 0.14),
                                value: animate
                            )
                    }
                }
            }
            .frame(height: 9)
        }
    }

    private func barFill(_ bar: Bar) -> LinearGradient {
        if bar.emphasized {
            return LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white, Color.white.opacity(0.9)]
                    : [Color.primary, Color.primary.opacity(0.85)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [
                AdaptiveChrome.fill(colorScheme, dark: 0.32, light: 0.26),
                AdaptiveChrome.fill(colorScheme, dark: 0.16, light: 0.13)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

// MARK: - Security gauge ring

/// A circular gauge whose stroke sweeps to `target` on appear. The center holds a
/// glyph + two short labels. Used for the encryption story.
struct OnboardingSecurityRing: View {
    var target: Double = 1.0     // 0...1
    let glyph: String
    let title: String
    let subtitle: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Soft aura
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.10 : 0.06),
                            .clear
                        ],
                        center: .center, startRadius: 6, endRadius: 95
                    )
                )
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)

            // Track
            Circle()
                .stroke(AdaptiveChrome.fill(colorScheme, dark: 0.08), lineWidth: 9)

            // Tick marks
            ForEach(0..<48, id: \.self) { i in
                Capsule()
                    .fill(AdaptiveChrome.fill(colorScheme, dark: i % 4 == 0 ? 0.18 : 0.08))
                    .frame(width: 1.4, height: i % 4 == 0 ? 6 : 3)
                    .offset(y: -78)
                    .rotationEffect(.degrees(Double(i) / 48 * 360))
            }

            // Progress sweep
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white, Color.white.opacity(0.75)]
                            : [Color.primary, Color.primary.opacity(0.7)],
                        startPoint: .topTrailing, endPoint: .bottomLeading
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.4 : 0), radius: 9)

            VStack(spacing: 4) {
                Image(systemName: glyph)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.92))
                    .symbolEffect(.pulse, options: .repeating.speed(0.35), isActive: appeared && !reduceMotion)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.tertiary)
            }
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)
        }
        .frame(width: 172, height: 172)
        .onAppear {
            guard !reduceMotion else {
                progress = target; appeared = true; return
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            withAnimation(.easeOut(duration: 1.35).delay(0.15)) { progress = target }
        }
    }
}

// MARK: - Pulsing feature glyph

/// A medallion-framed SF Symbol with concentric pulsing rings and one slow orbiting
/// dot. Reused for the wallet / VPN feature rows.
struct OnboardingPulseGlyph: View {
    let symbol: String
    var size: CGFloat = 52

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                ringBase
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate

                    ZStack {
                        // Two outward-pulsing rings (offset phase)
                        ForEach(0..<2, id: \.self) { i in
                            let phase = (t * 0.5 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.0)
                            Circle()
                                .strokeBorder(
                                    AdaptiveChrome.border(colorScheme, dark: 0.22 * (1 - phase)),
                                    lineWidth: 1
                                )
                                .frame(width: size * (1 + phase * 0.7), height: size * (1 + phase * 0.7))
                        }

                        ringBase

                        // Orbiting dot
                        let angle = t * 0.9
                        Circle()
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.85 : 0.5))
                            .frame(width: 3.5, height: 3.5)
                            .offset(x: cos(angle) * (size * 0.62), y: sin(angle) * (size * 0.62))
                            .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.6 : 0), radius: 3)
                    }
                }
            }
        }
        .frame(width: size * 1.9, height: size * 1.9)
    }

    private var ringBase: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(.primary.opacity(0.92))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.10))
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [
                                    AdaptiveChrome.border(colorScheme, dark: 0.28),
                                    AdaptiveChrome.border(colorScheme, dark: 0.06)
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    )
                    .shadow(color: AdaptiveChrome.shadow(colorScheme, darkOpacity: 0.35), radius: 12, y: 5)
            )
    }
}

// MARK: - Encrypted tunnel strip

/// A horizontal "tunnel" with packets flowing left→right that scramble past a central
/// lock — a compact way to show encrypted VPN traffic. Monochrome.
struct OnboardingTunnelStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dot: Color { colorScheme == .dark ? .white : .primary }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.14), lineWidth: 1)

            if reduceMotion {
                packetRow(progressOffsets: [0.15, 0.4, 0.7])
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    GeometryReader { geo in
                        Canvas { ctx, size in
                            let count = 5
                            let lock = size.width * 0.5
                            for i in 0..<count {
                                let speed = 0.10
                                let p = ((t * speed) + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1.0)
                                let x = size.width * CGFloat(p)
                                let y = size.height / 2
                                // Fade in/out at the tube ends
                                let edge = min(p, 1 - p) / 0.12
                                let alpha = min(1, edge) * 0.85
                                // Past the lock, packets become ciphertext ticks
                                let encrypted = x > lock
                                let color = dot.opacity(alpha * (encrypted ? 0.5 : 1.0))
                                if encrypted {
                                    let r = CGRect(x: x - 1, y: y - 3, width: 2, height: 6)
                                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(color))
                                } else {
                                    let r = CGRect(x: x - 2.4, y: y - 2.4, width: 4.8, height: 4.8)
                                    ctx.fill(Path(ellipseIn: r), with: .color(color))
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }

            // Central lock node
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .padding(6)
                .background(
                    Circle()
                        .fill(AdaptiveChrome.appCanvas(colorScheme, glassEnabled: true))
                        .overlay(Circle().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.3), lineWidth: 1))
                )
        }
        .frame(height: 30)
    }

    private func packetRow(progressOffsets: [Double]) -> some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(progressOffsets.enumerated()), id: \.offset) { _, p in
                    Circle()
                        .fill(dot.opacity(0.7))
                        .frame(width: 4.8, height: 4.8)
                        .position(x: geo.size.width * p, y: geo.size.height / 2)
                }
            }
        }
    }
}

// MARK: - Shooting stars overlay

/// A handful of occasional diagonal star streaks layered over the ambient starfield
/// for the welcome hero. Subtle, monochrome, and disabled under Reduce Motion.
struct OnboardingShootingStars: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let color = colorScheme == .dark ? Color.white : Color.primary
                    for i in 0..<4 {
                        let period = 7.0 + Double(i) * 2.3
                        let local = (t + Double(i) * 3.1).truncatingRemainder(dividingBy: period) / period
                        guard local < 0.16 else { continue }          // quick streak, then rest
                        let p = local / 0.16                            // 0...1 along the streak
                        let startX = size.width * CGFloat(0.12 + Double((i * 37) % 55) / 100.0)
                        let startY = size.height * CGFloat(0.04 + Double((i * 53) % 28) / 100.0)
                        let dx = size.width * 0.26
                        let dy = size.height * 0.20
                        let hx = startX + dx * CGFloat(p)
                        let hy = startY + dy * CGFloat(p)
                        let tailP = max(0, p - 0.14)
                        let tx = startX + dx * CGFloat(tailP)
                        let ty = startY + dy * CGFloat(tailP)
                        let alpha = sin(p * .pi) * 0.55

                        var path = Path()
                        path.move(to: CGPoint(x: tx, y: ty))
                        path.addLine(to: CGPoint(x: hx, y: hy))
                        ctx.stroke(
                            path,
                            with: .color(color.opacity(alpha)),
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                        )
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: hx - 1.5, y: hy - 1.5, width: 3, height: 3)),
                            with: .color(color.opacity(min(1, alpha * 1.5)))
                        )
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Launch transform + burst (onboarding → app reveal)

/// Drives the whole-onboarding "launch" transform via `.keyframeAnimator`.
struct OnboardingLaunchPose {
    var scale: Double = 1
    var opacity: Double = 1
    var blur: Double = 0
}

/// A one-shot light burst used as the onboarding hands off to the app: a soft bloom plus
/// an expanding shockwave ring, both fading out to reveal the app.
struct OnboardingLaunchBurst: View {
    @Environment(\.colorScheme) private var colorScheme

    private struct Anim {
        var scale: Double
        var opacity: Double
    }

    var body: some View {
        ZStack {
            // Soft central bloom
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.95 : 0.7),
                            Color.white.opacity(0.0)
                        ],
                        center: .center, startRadius: 0, endRadius: 320
                    )
                )
                .frame(width: 440, height: 440)
                .keyframeAnimator(initialValue: Anim(scale: 0.2, opacity: 0)) { view, v in
                    view.scaleEffect(v.scale).opacity(v.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        SpringKeyframe(0.85, duration: 0.16)
                        CubicKeyframe(3.0, duration: 0.55)
                    }
                    KeyframeTrack(\.opacity) {
                        CubicKeyframe(0.9, duration: 0.18)
                        CubicKeyframe(0.0, duration: 0.55)
                    }
                }

            // Expanding shockwave ring
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.85 : 0.55), lineWidth: 2.5)
                .frame(width: 150, height: 150)
                .keyframeAnimator(initialValue: Anim(scale: 0.25, opacity: 0)) { view, v in
                    view.scaleEffect(v.scale).opacity(v.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.4, duration: 0.06)
                        SpringKeyframe(5.0, duration: 0.66)
                    }
                    KeyframeTrack(\.opacity) {
                        CubicKeyframe(0.9, duration: 0.12)
                        CubicKeyframe(0.0, duration: 0.56)
                    }
                }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

// MARK: - Pill / fact chip

/// A small monochrome pill used for inline facts under headlines and charts.
struct OnboardingFactPill: View {
    let icon: String
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 1)
                )
        )
    }
}

// MARK: - Rich feature row (icon visual + copy)

/// A feature row with a pulsing glyph on the left and copy on the right, optionally
/// trailed by a custom visual (e.g. the tunnel strip). Used on the Wallet & VPN step.
struct OnboardingFeaturePanel<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var badge: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            OnboardingPulseGlyph(symbol: symbol, size: 46)
                .frame(width: 78)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.primary)
                    if let badge {
                        Text(badge.uppercased())
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)))
                    }
                }
                Text(detail)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                trailing()
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.06 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    AdaptiveChrome.border(colorScheme, dark: 0.16),
                                    AdaptiveChrome.border(colorScheme, dark: 0.05)
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
        )
    }
}

extension OnboardingFeaturePanel where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String, badge: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail, badge: badge) { EmptyView() }
    }
}
