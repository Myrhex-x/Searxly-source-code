//
//  OnboardingAIStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingAIStep: View {
    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Searxly AI",
            title: "An assistant that works for you — privately",
            subtitle: "Ask anything, summarize any page, or search the web — answered by an open model through Searxly's private cloud. Connect your in-app wallet (free, no payment) and you're in.",
            pills: [
                OnboardingPill(icon: "sparkles", text: "Ask · summarize · search"),
                OnboardingPill(icon: "lock.fill", text: "Private & grounded"),
                OnboardingPill(icon: "wallet.pass.fill", text: "Free with your wallet")
            ]
        ) {
            OnboardingAIDemo()
        }
    }
}
