//
//  OnboardingVPNStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingVPNStep: View {
    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Built-in VPN",
            title: "Hide your traffic in one tap",
            subtitle: "A WireGuard tunnel encrypts everything before it leaves the Mac and hides your IP from the sites you visit. Modern, fast, and logs nothing. Watch it connect.",
            pills: [
                OnboardingPill(icon: "lock.fill", text: "WireGuard tunnel"),
                OnboardingPill(icon: "eye.slash.fill", text: "IP hidden"),
                OnboardingPill(icon: "bolt.fill", text: "Fast & modern")
            ]
        ) {
            OnboardingVPNDemo()
        }
    }
}
