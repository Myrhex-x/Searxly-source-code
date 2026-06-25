//
//  OnboardingEncryptionStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingEncryptionStep: View {
    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "On-device vault",
            title: "Your data locks to this device",
            subtitle: "Passwords, history and wallet keys are sealed with AES-256. The keys are generated in this Mac's Keychain and never leave it — and never touch a Searxly server, because there isn't one.",
            pills: [
                OnboardingPill(icon: "key.fill", text: "Keychain-held keys"),
                OnboardingPill(icon: "icloud.slash.fill", text: "Nothing syncs"),
                OnboardingPill(icon: "doc.badge.gearshape", text: "Recovery code")
            ]
        ) {
            OnboardingEncryptionDemo()
        }
    }
}
