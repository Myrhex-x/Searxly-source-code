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
    /// the macOS app, which supports both modes. The home page overrides this to stay a dark hero.
    private static func adaptive(dark: Color, light: Color) -> Color {
        Color(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let bg        = adaptive(dark: Color(white: 0.04), light: Color(white: 0.99))
    static let surface   = adaptive(dark: Color(white: 0.10), light: Color(white: 0.94))
    static let surfaceHi = adaptive(dark: Color(white: 0.14), light: Color(white: 0.89))

    static let text          = adaptive(dark: .white,               light: Color(white: 0.06))
    static let textSecondary = adaptive(dark: .white.opacity(0.55), light: .black.opacity(0.55))
    static let textTertiary  = adaptive(dark: .white.opacity(0.35), light: .black.opacity(0.42))

    static let hairline      = adaptive(dark: .white.opacity(0.08), light: .black.opacity(0.10))
}

extension Text {
    /// Large, commanding result title (macOS SERP parity, tuned for phone).
    func resultTitle() -> some View {
        self.font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Brand.text)
            .lineLimit(2)
    }

    /// Tiny, muted URL/host line under a result.
    func resultHost() -> some View {
        self.font(.system(size: 12.5))
            .foregroundStyle(Brand.textTertiary)
            .lineLimit(1)
    }

    /// Result snippet/description.
    func resultSnippet() -> some View {
        self.font(.system(size: 14.5))
            .foregroundStyle(Brand.textSecondary)
            .lineLimit(3)
    }
}
