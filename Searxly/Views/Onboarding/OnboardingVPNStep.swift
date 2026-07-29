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
            subtitle: "Flip one switch and your connection routes through an encrypted tunnel to Searxly's own exit node — hiding your IP from every site you visit. It keeps no logs. Watch it connect.",
            pills: [
                OnboardingPill(icon: "lock.fill", text: "Encrypted tunnel"),
                OnboardingPill(icon: "eye.slash.fill", text: "IP hidden"),
                OnboardingPill(icon: "nosign", text: "No logs kept")
            ]
        ) {
            OnboardingVPNDemo()
        }
    }
}
