//
//  OnboardingFeatureSlide.swift
//  Searxly
//
//  A presentation-style scaffold for the feature steps. On a wide window it lays out as
//  a landing-page split — big copy on the left, a large live demo on the right — and
//  stacks vertically when narrow. Everything reveals in a staggered entrance.
//

import SwiftUI

struct OnboardingPill: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

struct OnboardingFeatureSlide<Demo: View, Extra: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var pills: [OnboardingPill] = []
    @ViewBuilder var demo: () -> Demo
    @ViewBuilder var extra: () -> Extra

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= OnboardingStyle.wideBreakpoint

            Group {
                if wide {
                    HStack(alignment: .center, spacing: 44) {
                        textColumn(alignment: .leading)
                            .frame(width: min(380, geo.size.width * 0.40), alignment: .leading)
                        demoColumn
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 26) {
                            textColumn(alignment: .center)
                            demoColumn
                        }
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { revealed = true }
    }

    private func textColumn(alignment: HorizontalAlignment) -> some View {
        let textAlign: TextAlignment = alignment == .leading ? .leading : .center
        let frameAlign: Alignment = alignment == .leading ? .leading : .center

        return VStack(alignment: alignment, spacing: 16) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(.tertiary)
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.02)

            Text(title)
                .font(.system(size: 33, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(textAlign)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.08)

            Text(subtitle)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(textAlign)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.14)

            if !pills.isEmpty {
                FlowPills(pills: pills, alignment: alignment)
                    .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.2)
            }

            extra()
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.26)
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    private var demoColumn: some View {
        ZStack {
            // Soft aura behind the demo so it reads as the hero.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.07 : 0.05),
                            .clear
                        ],
                        center: .center, startRadius: 10, endRadius: 360
                    )
                )
                .blur(radius: 12)
                .scaleEffect(1.08)

            demo()
                .frame(maxWidth: 560)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.96)
                .opacity(revealed || reduceMotion ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82).delay(0.12), value: revealed)
        }
        .frame(maxWidth: .infinity)
    }
}

extension OnboardingFeatureSlide where Extra == EmptyView {
    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        pills: [OnboardingPill] = [],
        @ViewBuilder demo: @escaping () -> Demo
    ) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, pills: pills, demo: demo) { EmptyView() }
    }
}

/// Pills laid out in a row that wraps to a second line if needed.
private struct FlowPills: View {
    let pills: [OnboardingPill]
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            // Up to 3 per row keeps it tidy across both layouts.
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { pill in
                        OnboardingFactPill(icon: pill.icon, text: pill.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }

    private var chunks: [[OnboardingPill]] {
        stride(from: 0, to: pills.count, by: 3).map {
            Array(pills[$0..<min($0 + 3, pills.count)])
        }
    }
}
