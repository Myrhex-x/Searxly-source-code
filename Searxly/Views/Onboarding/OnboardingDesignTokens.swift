//
//  OnboardingDesignTokens.swift
//  Searxly
//

import SwiftUI

enum OnboardingStyle {
    static let stepCount = 10
    static let stepLabels = ["Welcome", "Search", "News", "Encryption", "Wallet", "VPN", "Tor", "Searxly AI", "Security", "Ready"]

    /// Raw step index of the Searxly AI slide. It's skipped entirely while the AI program is off
    /// (`AIFeatures.programEnabled`), so the flow hops over it — see `OnboardingFlow.advance/goBack`.
    static let aiStepIndex = 7

    /// The steps actually reachable right now, in order. Excludes the AI slide when the AI program is
    /// off, so the progress dots + "N of M" counter never number or count a step the user can't land
    /// on (which produced a visible gap: "6 of 9" jumping straight to "8 of 9").
    static var visibleSteps: [Int] {
        AIFeatures.programEnabled ? Array(0..<stepCount) : (0..<stepCount).filter { $0 != aiStepIndex }
    }
    static var visibleStepCount: Int { visibleSteps.count }
    /// 1-based position of a raw step within the visible sequence (for "N of M").
    static func displayPosition(of step: Int) -> Int { (visibleSteps.firstIndex(of: step) ?? 0) + 1 }

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