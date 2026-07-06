//
//  AdaptiveChrome.swift
//  Searxly
//
//  Semantic glass / border / fill colors that work in both light and dark mode.
//

import SwiftUI

enum AdaptiveChrome {
    /// Shared slim header + expanded sidebar top row height so chrome dividers meet cleanly.
    static let slimToolbarRowHeight: CGFloat = 40

    /// A color that resolves per appearance at draw time. Lets static theme tokens
    /// (SettingsTheme, pill/menu themes) become adaptive without changing call sites —
    /// resolution follows the view's effectiveAppearance, which tracks the app's
    /// Appearance setting via the root `.preferredColorScheme`.
    static func dynamic(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    /// Deep premium canvas — home hero, sidebar, header, and main chrome in dark + glass mode.
    static let canvasDark = Color(red: 0.043, green: 0.043, blue: 0.051)

    /// Paper-white counterpart for light + glass mode — a hair brighter and cooler than the stock
    /// window gray so light mode reads as designed, not defaulted.
    static let canvasLight = Color(red: 0.973, green: 0.973, blue: 0.98)

    /// The exact solid panel canvas the floating sidebar + VPN popovers use (near-black in dark, white
    /// in light). Shared so SERP chrome (category tabs, news control bar) can sit at the SAME darkness
    /// as the sidebar instead of a light frosted material. One definition → the surfaces can't drift.
    static var panelCanvas: Color { dynamic(light: .white, dark: canvasDark) }

    /// Shared app background. Glass mode uses the designed canvas (near-black / paper-white);
    /// otherwise system window bg.
    static func appCanvas(_ scheme: ColorScheme, glassEnabled: Bool) -> Color {
        guard glassEnabled else {
            #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return Color(uiColor: .systemBackground)
            #endif
        }
        return scheme == .dark ? canvasDark : canvasLight
    }

    static func fill(_ scheme: ColorScheme, dark: Double, light: Double? = nil) -> Color {
        let lightOpacity = light ?? min(dark * 1.5, 0.14)
        return scheme == .dark ? Color.white.opacity(dark) : Color.primary.opacity(lightOpacity)
    }

    static func border(_ scheme: ColorScheme, dark: Double, light: Double? = nil) -> Color {
        let lightOpacity = light ?? min(dark * 1.8, 0.22)
        return scheme == .dark ? Color.white.opacity(dark) : Color.primary.opacity(lightOpacity)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        fill(scheme, dark: 0.06, light: 0.09)
    }

    static func panelTint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.04) : Color.primary.opacity(0.03)
    }

    static func shadow(_ scheme: ColorScheme, darkOpacity: Double) -> Color {
        Color.black.opacity(scheme == .dark ? darkOpacity : darkOpacity * 0.5)
    }

    static func pressedOverlay(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.08) : Color.primary.opacity(0.06)
    }
}