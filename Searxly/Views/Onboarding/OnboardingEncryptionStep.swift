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
            // Maximum: password vault is a product feature. Base: wallet is. Neither edition
            // advertises the other edition's exclusive surfaces.
            subtitle: Edition.isMaximum
                ? "Passwords, history and bookmarks are sealed with AES-256. The keys are generated in this Mac's Keychain and never leave it — there's no Searxly account and nothing to sync, so your encrypted data has nowhere else to go."
                : "History, bookmarks and wallet keys are sealed with AES-256. The keys are generated in this Mac's Keychain and never leave it — there's no Searxly account and nothing to sync, so your encrypted data has nowhere else to go.",
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
