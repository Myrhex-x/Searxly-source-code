//
//  OnboardingWelcomeStep.swift
//  Searxly
//
//  The cinematic opening: a hero logo orbiting over the starfield, a one-line promise,
//  and big count-up stats that establish the product the moment the app opens.
//

import SwiftUI

struct OnboardingWelcomeStep: View {
    let glassEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            SearxlyLogo(
                glassEnabled: glassEnabled,
                size: 78,
                style: .hero,
                animated: !reduceMotion,
                showShine: glassEnabled && !reduceMotion,
                showTagline: false
            )
            .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0)
            .padding(.bottom, 34)

            VStack(spacing: 14) {
                Text("The private browser that keeps\neverything on your Mac.")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Text("Search, wallet, and VPN — all built in. No accounts, no cloud, nothing that can leak.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 500)
            }
            .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.08)
            .padding(.bottom, 38)

            HStack(spacing: 14) {
                OnboardingStatChip(target: 100, suffix: "%", caption: "On-device", delay: 0.30)
                OnboardingStatChip(target: 0, caption: "Trackers", delay: 0.42)
                OnboardingStatChip(target: 256, suffix: "-bit", caption: "Encryption", delay: 0.54)
            }
            .frame(maxWidth: 540)
            .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.18)

            Spacer(minLength: 12)

            Text("PRIVATE  ·  YOURS  ·  LOCAL")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(3.6)
                .foregroundStyle(.tertiary.opacity(0.7))
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.30)
                .padding(.top, 14)
        }
        .frame(maxWidth: 620, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { revealed = true }
    }
}
