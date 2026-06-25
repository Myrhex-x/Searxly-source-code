//
//  OnboardingReadyStep.swift
//  Searxly
//
//  The closing screen: a staggered "what's protecting you" checklist that animates in,
//  reflecting the choices made during onboarding.
//

import SwiftUI

struct OnboardingReadyStep: View {
    let glassEnabled: Bool
    let localSearchReady: Bool
    let privacyLabel: String
    let appLockEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var rows: [SummaryRow] {
        [
            SummaryRow(
                done: localSearchReady,
                title: localSearchReady ? "Local SearXNG active" : "Local search",
                detail: localSearchReady
                    ? "Your private engine is running on this Mac."
                    : "It'll finish setting up — start it anytime in Settings."
            ),
            SummaryRow(done: true, title: privacyLabel, detail: "Browsing data is protected on this device."),
            SummaryRow(
                done: appLockEnabled,
                title: appLockEnabled ? "App Lock enabled" : "App Lock off",
                detail: appLockEnabled
                    ? "Touch ID or your password is required to open Searxly."
                    : "Turn it on anytime in Settings → Privacy."
            ),
            SummaryRow(done: true, title: "Wallet & VPN ready", detail: "Self-custody wallet and WireGuard VPN are built in.")
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            SearxlyLogo(
                glassEnabled: glassEnabled,
                size: 68,
                style: .hero,
                animated: !reduceMotion,
                showShine: glassEnabled && !reduceMotion,
                showTagline: false
            )
            .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0)
            .padding(.bottom, 26)

            VStack(spacing: 9) {
                Text("You're all set.")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.primary)
                Text("Everything you just saw runs right here on your Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.06)
            .padding(.bottom, 30)

            VStack(spacing: 9) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    summaryRow(row)
                        .onboardingVisualReveal(
                            revealed,
                            reduceMotion: reduceMotion,
                            delay: 0.14 + Double(index) * 0.08
                        )
                }
            }
            .frame(maxWidth: 500)

            Spacer(minLength: 4)

            Text("PRIVATE  ·  YOURS  ·  LOCAL")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(3.6)
                .foregroundStyle(.tertiary.opacity(0.7))
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.5)
                .padding(.top, 18)
        }
        .frame(maxWidth: 560, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { revealed = true }
    }

    private struct SummaryRow {
        let done: Bool
        let title: String
        let detail: String
    }

    private func summaryRow(_ row: SummaryRow) -> some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack {
                Circle()
                    .fill(AdaptiveChrome.fill(colorScheme, dark: row.done ? 0.14 : 0.06))
                    .overlay(
                        Circle().strokeBorder(
                            AdaptiveChrome.border(colorScheme, dark: row.done ? 0.26 : 0.10),
                            lineWidth: 1
                        )
                    )
                    .frame(width: 34, height: 34)
                if row.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                } else {
                    // A simple centered dot reads as "pending" without the off-center
                    // dotted-circle artifacting.
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 5, height: 5)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(row.done ? AnyShapeStyle(.primary.opacity(0.92)) : AnyShapeStyle(.secondary))
                Text(row.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: row.done ? 0.07 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: row.done ? 0.14 : 0.08), lineWidth: 1)
                )
        )
    }
}
