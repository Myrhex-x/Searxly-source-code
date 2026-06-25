//
//  OnboardingWalletStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingWalletStep: View {
    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Self-custody wallet",
            title: "A wallet that's truly yours",
            subtitle: "A real Base wallet is built right in. Your seed phrase and private keys are created on this Mac and held in the Keychain — there's no custodian, no account, and nothing for anyone else to lose.",
            pills: [
                OnboardingPill(icon: "key.horizontal.fill", text: "Keys on-device"),
                OnboardingPill(icon: "person.crop.circle.badge.xmark", text: "No account"),
                OnboardingPill(icon: "arrow.left.arrow.right", text: "Swap built in")
            ]
        ) {
            OnboardingWalletDemo()
        }
    }
}
