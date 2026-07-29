//
//  Theme.swift
//  SearxlyiOS
//
//  The start of the iOS design system — the Searxly monochrome palette + SERP typography, mirroring
//  the macOS app's "expensive calm": large bold result titles, tiny muted URLs, generous rhythm.
//

import SwiftUI
import UIKit

enum Brand {
    /// Monochrome that flips with the system appearance (dark ⇄ light) — Safari-like, and matching
    /// the macOS app, which supports both modes. Dark canvas is pure black like searxly.app.
    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// Pure black in dark — same canvas as searxly.app (`--bg: #000` / `--bg-raised: #000`).
    static let bg        = adaptive(dark: .black, light: UIColor(white: 0.99, alpha: 1))
    /// White-alpha veils on pure black (site surfaces), so cards read without greying the canvas.
    static let surface   = adaptive(dark: UIColor.white.withAlphaComponent(0.06),
                                    light: UIColor(white: 0.94, alpha: 1))
    static let surfaceHi = adaptive(dark: UIColor.white.withAlphaComponent(0.10),
                                    light: UIColor(white: 0.89, alpha: 1))

    static let text          = adaptive(dark: .white, light: UIColor(white: 0.06, alpha: 1))
    static let textSecondary = adaptive(dark: UIColor.white.withAlphaComponent(0.55),
                                        light: UIColor.black.withAlphaComponent(0.55))
    static let textTertiary  = adaptive(dark: UIColor.white.withAlphaComponent(0.35),
                                        light: UIColor.black.withAlphaComponent(0.42))

    static let hairline      = adaptive(dark: UIColor.white.withAlphaComponent(0.08),
                                        light: UIColor.black.withAlphaComponent(0.10))

    /// One shared Liquid Glass tint for floating surfaces (AI overview, summary sheet, banners),
    /// matching the bottom bar's proven depth: glass DARKENS over the page in dark mode — a white
    /// tint there reads as a washed-out bright slab — and stays near-invisible in light.
    static func glassTint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.05)
    }

    /// Broadcast "live" red — the only non-monochrome accent, scoped to news urgency (LIVE / BREAKING
    /// badges and sub-hour timestamps), mirroring the macOS app. Brighter in dark for pop, deeper in
    /// light. Green stays reserved for price/status meaning; red never decorates.
    static let liveRed = adaptive(
        dark:  UIColor(red: 1.0,  green: 0.27, blue: 0.23, alpha: 1),
        light: UIColor(red: 0.80, green: 0.09, blue: 0.07, alpha: 1)
    )

    // MARK: - Dimensional scales
    // The palette above is tokenized; these give size, spacing, and radius the same discipline so the
    // whole app shares one rhythm instead of ~28 ad-hoc font sizes / 13 radii scattered across files.

    /// Spacing on a 4-pt grid.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Three corner-radius tiers — controls (pills/buttons), cards, and the floating bar.
    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let bar: CGFloat = 26
    }

    /// Type ramp (point sizes; pair with `.scaledFont(size:)` so Dynamic Type still applies).
    enum FontSize {
        static let micro: CGFloat = 11     // badges, tracking labels
        static let caption: CGFloat = 12   // hosts, meta
        static let footnote: CGFloat = 13  // secondary body
        static let body: CGFloat = 15      // default body
        static let headline: CGFloat = 17  // section titles, emphasis
        static let title: CGFloat = 20     // screen titles
        static let display: CGFloat = 28   // hero numerals
    }
}

/// The app's standard floating glass card — tinted Liquid Glass plus a hairline rim. One surface
/// recipe shared by the AI overview, summary sheet, and banners, so every floating card carries the
/// same calm depth in both appearances instead of each view mixing its own tint.
private struct SearxlyGlassCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(Brand.glassTint(scheme)), in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 0.5)
            )
    }
}

/// Capsule twin of `SearxlyGlassCard` for pill-shaped glass controls (docked action buttons).
private struct SearxlyGlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(Brand.glassTint(scheme)), in: .capsule)
            .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 0.5))
    }
}

extension View {
    func searxlyGlassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(SearxlyGlassCard(cornerRadius: cornerRadius))
    }

    func searxlyGlassCapsule() -> some View {
        modifier(SearxlyGlassCapsule())
    }
}

extension Text {
    /// Large, commanding result title (macOS SERP parity, tuned for phone).
    func resultTitle() -> some View {
        self.scaledFont(size: 19, weight: .semibold)
            .foregroundStyle(Brand.text)
            .lineLimit(2)
    }

    /// Tiny, muted URL/host line under a result.
    func resultHost() -> some View {
        self.scaledFont(size: 12)
            .foregroundStyle(Brand.textTertiary)
            .lineLimit(1)
    }

    /// Result snippet/description.
    func resultSnippet() -> some View {
        self.scaledFont(size: 14)
            .foregroundStyle(Brand.textSecondary)
            .lineLimit(3)
    }
}
