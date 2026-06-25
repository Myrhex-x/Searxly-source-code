//
//  OnboardingLocalSearchStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingLocalSearchStep: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Private search",
            title: "Search that never leaves your Mac",
            subtitle: "Searxly bundles its own SearXNG engine on 127.0.0.1 and aggregates results from dozens of sources — locally. No Searxly server ever sees your query.",
            pills: [
                OnboardingPill(icon: "house.fill", text: "Runs at 127.0.0.1"),
                OnboardingPill(icon: "rectangle.3.group.fill", text: "Dozens of engines"),
                OnboardingPill(icon: "nosign", text: "No query logs")
            ]
        ) {
            OnboardingSearchDemo()
        } extra: {
            VStack(alignment: .leading, spacing: 11) {
                Text("REQUESTS SENT TO THIRD-PARTY SERVERS · PER SESSION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)

                OnboardingBarChart(bars: [
                    .init(label: "Typical browser", caption: "Hundreds of calls", value: 1.0),
                    .init(label: "Private / incognito", caption: "Still tracked", value: 0.74),
                    .init(label: "Searxly", caption: "Nothing leaves your Mac", value: 0, emphasized: true)
                ])
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
}
