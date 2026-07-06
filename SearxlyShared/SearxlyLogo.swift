//
//  SearxlyLogo.swift
//  Searxly
//
//  SPACEX-inspired "SEARXLY" brand mark (exact match to searxly.app).
//

import SwiftUI

enum SearxlyLogoStyle {
    case compact
    case standard
    /// Home / onboarding hero — sunlight glow, gradient letters, entrance + shine.
    case hero
}

struct SearxlyLogo: View {
    var glassEnabled: Bool = true
    var size: CGFloat = 31.0
    var style: SearxlyLogoStyle = .standard
    var animated: Bool = false
    var showShine: Bool = false
    var showTagline: Bool = true

    private let letters = Array("SEARXLY")

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var shineActive = false
    @State private var isHovering = false
    /// Cursor-relative tilt angles, spring-animated. Range roughly -1…+1 normalised.
    @State private var hoverTiltX: Double = 0  // pitch  (up/down)
    @State private var hoverTiltY: Double = 0  // yaw    (left/right)

    private var letterSpacing: CGFloat { 19.0 * (size / 31.0) }
    private var taglineSize: CGFloat { 9.5 * (size / 31.0) }
    private var accentBarWidth: CGFloat { size * 4.8 }
    private var isHero: Bool { style == .hero }

    /// Width driven by letters only — glow/shine must not affect layout or rotation pivot.
    private var logoTextWidth: CGFloat {
        CGFloat(letters.count) * (size * 0.58) + CGFloat(letters.count - 1) * letterSpacing
    }

    var body: some View {
        VStack(spacing: max(4, 7 * (size / 31.0))) {
            logoMark
                .frame(width: logoTextWidth, height: size * 1.15)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard isHero || animated else { return }
                    switch phase {
                    case .active(let location):
                        let hoverAreaWidth = logoTextWidth + 36
                        let hoverAreaHeight = size * 1.15 + 20
                        let nx = max(-1, min(1, Double((location.x - hoverAreaWidth / 2) / (hoverAreaWidth / 2))))
                        let ny = max(-1, min(1, Double((location.y - hoverAreaHeight / 2) / (hoverAreaHeight / 2))))
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                            isHovering = true
                            hoverTiltY = nx * 6.0
                            hoverTiltX = -ny * 3.5
                        }
                    case .ended:
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                            isHovering = false
                            hoverTiltX = 0
                            hoverTiltY = 0
                        }
                    }
                }

            if isHero {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.18 : 0.12),
                                Color.white.opacity(colorScheme == .dark ? 0.45 : 0.35),
                                AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.18 : 0.12),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: accentBarWidth, height: 1.2)
                    .opacity((appeared || !shouldAnimateEntrance) ? (isHovering ? 1.0 : 0.9) : 0)
                    .scaleEffect(x: isHovering ? 1.04 : 1.0, y: 1.0)
            }

            if showTagline {
                Text("PRIVATE. YOURS.")
                    .font(.system(size: taglineSize, weight: .semibold, design: .default))
                    .kerning(3.2)
                    .foregroundStyle(taglineForeground)
                    .tracking(1.8)
            }
        }
        .accessibilityLabel("Searxly — Private. Yours.")
        .opacity(glassEnabled ? 0.98 : 0.92)
        .animation(.easeOut(duration: 0.22), value: glassEnabled)
        .onAppear { runEntranceIfNeeded() }
    }

    private var logoMark: some View {
        ZStack {
            if isHero && glassEnabled {
                heroGlowLayer
            }

            lettersRow
                // Clip the shine sweep to the text frame BEFORE any effects or 3D rotation.
                // Without this, the shine rectangle (offset far right) bleeds outside the logo
                // bounds and .blendMode(.screen) leaves a white artifact in Metal's render cache
                // that persists until a hover re-render clears it.
                .overlay {
                    if (animated || showShine) && shineActive {
                        shineSweep
                    }
                }
                .clipped()
                .shadow(color: heroShadowColor, radius: isHero ? 2.5 : 1.5, x: 0, y: isHero ? 1.5 : 1)
                .shadow(color: .black.opacity(isHero ? 0.28 : 0), radius: isHero ? 14 : 0, x: 0, y: isHero ? 6 : 0)
                .scaleEffect(appeared || !shouldAnimateEntrance ? 1.0 : 0.55)
                .opacity(appeared || !shouldAnimateEntrance ? 1.0 : 0.6)
                .modifier(LogoMotionEffect(isHero: isHero, hoverTiltX: hoverTiltX, hoverTiltY: hoverTiltY, reduceMotion: reduceMotion))
        }
        .frame(width: logoTextWidth, height: size * 1.15)
    }

    private var lettersRow: some View {
        HStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { index in
                letterView(at: index)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var heroGlowLayer: some View {
        if shouldAnimateEntrance && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let driftX = sin(time * 1.4) * (size * 0.06)
                let driftY = cos(time * 1.0) * (size * 0.03) - 2
                let hoverBoost = isHovering ? 1.12 : 1.0

                glowEllipse
                    .offset(x: driftX, y: driftY)
                    .scaleEffect(hoverBoost)
                    .blur(radius: isHovering ? 24 : 20)
                    .opacity((appeared || !shouldAnimateEntrance) ? (isHovering ? 1.0 : 0.9) : 0)
            }
            .allowsHitTesting(false)
        } else {
            glowEllipse
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .blur(radius: isHovering ? 24 : 20)
                .opacity((appeared || !shouldAnimateEntrance) ? (isHovering ? 1.0 : 0.88) : 0)
                .allowsHitTesting(false)
        }
    }

    private var glowEllipse: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(glowCoreOpacity),
                        Color.white.opacity(glowMidOpacity),
                        .clear
                    ],
                    center: .center,
                    startRadius: 4,
                    endRadius: size * 2.4
                )
            )
            .frame(width: logoTextWidth * 1.35, height: size * 2.6)
    }

    private var shineSweep: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.42),
                        Color.white.opacity(0.18),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: logoTextWidth * 0.55)
            .offset(x: shineActive ? logoTextWidth * 0.95 : -logoTextWidth * 0.75)
            .blendMode(.screen)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 1.1), value: shineActive)
    }

    private var glowCoreOpacity: Double {
        let base = colorScheme == .dark ? 0.16 : 0.22
        return isHovering ? min(base * 1.55, 0.38) : base
    }

    private var glowMidOpacity: Double {
        let base = colorScheme == .dark ? 0.05 : 0.08
        return isHovering ? min(base * 1.8, 0.16) : base
    }

    @ViewBuilder
    private func letterView(at index: Int) -> some View {
        let letter = String(letters[index])

        Text(letter)
            .font(.system(size: size, weight: .black, design: .default))
            .foregroundStyle(letterGradient)
            .kerning(0.6)
            .padding(.trailing, index < letters.count - 1 ? letterSpacing : 0)
            .scaleEffect(appeared || !shouldAnimateEntrance ? 1.0 : 0.85)
            .rotation3DEffect(
                .degrees(appeared || !shouldAnimateEntrance ? 0 : 12),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center
            )
    }

    private var letterGradient: LinearGradient {
        if isHero {
            return LinearGradient(
                colors: heroLetterColors,
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(colors: [logoSolidColor], startPoint: .top, endPoint: .bottom)
    }

    private var heroLetterColors: [Color] {
        if colorScheme == .dark {
            return [.white, Color.white.opacity(0.88)]
        }
        return glassEnabled
            ? [Color.primary, Color.primary.opacity(0.82)]
            : [Color.primary.opacity(0.9), Color.primary.opacity(0.74)]
    }

    private var logoSolidColor: Color {
        if colorScheme == .dark {
            return .white
        }
        return glassEnabled ? Color.primary : Color.primary.opacity(0.88)
    }

    private var heroShadowColor: Color {
        .black.opacity(isHero ? (glassEnabled ? 0.32 : 0.2) : (glassEnabled ? 0.25 : 0.15))
    }

    private var taglineForeground: Color {
        colorScheme == .dark
            ? (glassEnabled ? Color.white.opacity(0.55) : Color.white.opacity(0.48))
            : (glassEnabled ? Color.secondary : Color.secondary.opacity(0.85))
    }

    private var shouldAnimateEntrance: Bool {
        (animated || isHero) && !reduceMotion
    }

    private func runEntranceIfNeeded() {
        guard shouldAnimateEntrance else {
            appeared = true
            return
        }

        withAnimation(.spring(response: 0.58, dampingFraction: 0.82)) {
            appeared = true
        }

        guard animated || showShine || (isHero && glassEnabled) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            shineActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
                shineActive = false
            }
        }
    }
}

// MARK: - Symmetric hero motion (pivot stays on letter center)

private struct LogoMotionEffect: ViewModifier {
    let isHero: Bool
    let hoverTiltX: Double  // pitch, spring-animated by caller
    let hoverTiltY: Double  // yaw,  spring-animated by caller
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if isHero && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let idlePitch = sin(time * 1.1) * 1.4
                let idleYaw = sin(time * 0.85 + 0.6) * 1.1

                content
                    .rotation3DEffect(
                        .degrees(idlePitch + hoverTiltX),
                        axis: (x: 1, y: 0, z: 0),
                        anchor: .center,
                        perspective: 0.85
                    )
                    .rotation3DEffect(
                        .degrees(idleYaw + hoverTiltY),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .center,
                        perspective: 0.85
                    )
                    .offset(y: sin(time * 1.25) * 1.2)
            }
        } else {
            content
                .rotation3DEffect(
                    .degrees(hoverTiltX),
                    axis: (x: 1, y: 0, z: 0),
                    anchor: .center,
                    perspective: 0.85
                )
                .rotation3DEffect(
                    .degrees(hoverTiltY),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    perspective: 0.85
                )
        }
    }
}