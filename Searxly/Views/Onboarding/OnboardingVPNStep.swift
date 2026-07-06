//
//  OnboardingVPNStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingVPNStep: View {
    /// While the launch-week promo is running, the pass has already been comped for this new install
    /// (see VPNLaunchPromo) — so the slide announces the free week instead of the generic pitch.
    private var promoActive: Bool { VPNLaunchPromo.isWindowOpen }

    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: promoActive ? "Built-in VPN · First week free" : "Built-in VPN",
            title: promoActive ? "Your first week is on us" : "Hide your traffic in one tap",
            subtitle: promoActive
                ? "We've unlocked Searxly VPN free for your first week — no code, no card. Flip one switch and your connection routes through an encrypted tunnel to Searxly's own exit node, hiding your IP from every site you visit. It keeps no logs."
                : "Flip one switch and your connection routes through an encrypted tunnel to Searxly's own exit node — hiding your IP from every site you visit. It keeps no logs. Watch it connect.",
            pills: promoActive
                ? [
                    OnboardingPill(icon: "gift.fill", text: "7 days free"),
                    OnboardingPill(icon: "eye.slash.fill", text: "IP hidden"),
                    OnboardingPill(icon: "nosign", text: "No logs kept")
                  ]
                : [
                    OnboardingPill(icon: "lock.fill", text: "Encrypted tunnel"),
                    OnboardingPill(icon: "eye.slash.fill", text: "IP hidden"),
                    OnboardingPill(icon: "nosign", text: "No logs kept")
                  ]
        ) {
            OnboardingVPNDemo()
        }
    }
}
