//
//  OnboardingDesignTokens.swift
//  Searxly
//

import SwiftUI

enum OnboardingStyle {
    static let stepCount = 7
    static let stepLabels = ["Welcome", "Search", "Encryption", "Wallet", "VPN", "Security", "Ready"]

    static let stepSpring = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let cardSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let revealSpring = Animation.spring(response: 0.5, dampingFraction: 0.82)
    static let minTapHeight: CGFloat = 48
    /// Width budget for the two-column feature slides.
    static let contentMaxWidth: CGFloat = 980
    /// Narrower budget for the centered steps (welcome, security, ready).
    static let centeredContentWidth: CGFloat = 680
    /// Below this content width, feature slides stack vertically instead of two-column.
    static let wideBreakpoint: CGFloat = 840
    static let cardCornerRadius: CGFloat = 16
    static let buttonCardCornerRadius: CGFloat = 12
}

private struct OnboardingGlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var onboardingGlassEnabled: Bool {
        get { self[OnboardingGlassEnabledKey.self] }
        set { self[OnboardingGlassEnabledKey.self] = newValue }
    }
}

extension View {
    func onboardingGlassEnabled(_ enabled: Bool) -> some View {
        environment(\.onboardingGlassEnabled, enabled)
    }
}