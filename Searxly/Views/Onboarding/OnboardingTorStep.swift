//
//  OnboardingTorStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingTorStep: View {
    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Onion routing",
            title: "Reach .onion sites, anonymously",
            subtitle: "Open any .onion address and Searxly routes that one tab through the Tor network — bouncing it across three relays so the site never sees your real IP. Tor is bundled, so there's nothing to install.",
            pills: [
                OnboardingPill(icon: "point.3.connected.trianglepath.dotted", text: "3-hop circuit"),
                OnboardingPill(icon: "eye.slash.fill", text: "Real IP hidden"),
                OnboardingPill(icon: "shippingbox.fill", text: "Tor built in")
            ]
        ) {
            OnboardingTorDemo()
        }
    }
}
