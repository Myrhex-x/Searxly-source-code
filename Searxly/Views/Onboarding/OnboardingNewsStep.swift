//
//  OnboardingNewsStep.swift
//  Searxly
//
//  Onboarding slide introducing the live-news surface (home topics + News tab) and how it stays
//  private: every story is fetched through the user's own bundled SearXNG, so no news site sees them.
//

import SwiftUI

struct OnboardingNewsStep: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Live news",
            title: "The day's news, fetched privately",
            subtitle: "A live top story and topics you choose — World, War, Politics, Tech, Business and more — pulled fresh through your own SearXNG on 127.0.0.1. No news site or aggregator ever sees your IP or what you read.",
            pills: [
                OnboardingPill(icon: "bolt.fill", text: "Live top story"),
                OnboardingPill(icon: "square.grid.2x2.fill", text: "Topics you pick"),
                OnboardingPill(icon: "eye.slash.fill", text: "No site sees you")
            ]
        ) {
            OnboardingNewsDemo()
        } extra: {
            VStack(alignment: .leading, spacing: 12) {
                Text("HOW IT STAYS PRIVATE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    flowNode("You", "person.fill")
                    connector
                    flowNode("Your SearXNG", "house.fill", mono: "127.0.0.1")
                    connector
                    flowNode("News sites", "globe")
                }

                Text("News sites only ever see requests from your own local instance — never your IP, your identity, or which stories you open.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(15)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.10), lineWidth: 1)
                    )
            )
            .padding(.top, 4)
        }
    }

    private func flowNode(_ label: String, _ icon: String, mono: String? = nil) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.10))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.14), lineWidth: 1)
                )
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.primary)
            if let mono {
                Text(mono).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var connector: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.tertiary)
    }
}
