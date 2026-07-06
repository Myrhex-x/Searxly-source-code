//
//  SearxlyFloatingPanel.swift
//  Searxly
//
//  The shared "floating panel" chrome: the exact surface treatment of the floating tab sidebar,
//  reusable by any card that should read as the same material (currently the sidebar and the SERP
//  knowledge panel). One definition so the surfaces can never drift apart.
//
//  Recipe (monochrome, brand): solid VPN-popover canvas (near-black in dark, white in light) with
//  SUPER-round continuous corners, a faint top-down white sheen, a rim-light gradient border
//  (bright top edge fading down — the edge of real glass), and a layered shadow (tight contact
//  line + deep soft ambient). Solid by design: identical whether liquid glass is on or reduced.
//

import SwiftUI

struct SearxlyFloatingPanelStyle: ViewModifier {
    var cornerRadius: CGFloat = 18
    /// Pass the app-resolved scheme where the appearance override matters (the sidebar does);
    /// nil follows the environment (right for content inside the normal hierarchy).
    var schemeOverride: ColorScheme? = nil
    /// Panel surface override. nil = the VPN-popover canvas (sidebar / knowledge card). Surfaces
    /// stacked on an already-near-black canvas (Settings section cards) pass a slightly raised
    /// color instead, or the panel would vanish into the page.
    var surface: Color? = nil
    /// Shadow scale: 1 = a lone floating panel (sidebar / knowledge card); smaller for repeated
    /// cards in a scroll (Settings sections), where full-strength shadows get loud.
    var elevation: CGFloat = 1

    @Environment(\.colorScheme) private var envScheme

    private var scheme: ColorScheme { schemeOverride ?? envScheme }
    private var isDark: Bool { scheme == .dark }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var surfaceColor: Color {
        surface ?? AdaptiveChrome.panelCanvas
    }

    func body(content: Content) -> some View {
        content
            // Clip the content first so hover fills / banners respect the corners.
            .clipShape(shape)
            // The surface: the EXACT panel canvas the VPN / Tor / Passwords pill popovers use
            // (unless the call site raised it for contrast).
            .background(shape.fill(surfaceColor))
            // Faint top-down sheen, dying out a third of the way — premium-glass cue, never a color.
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(isDark ? 0.055 : 0.10), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.38)
                ))
                .allowsHitTesting(false)
            )
            // Rim light instead of a flat hairline: brighter along the top edge where the sheen hits.
            .overlay(shape.strokeBorder(
                LinearGradient(
                    colors: [
                        AdaptiveChrome.dynamic(light: Color.black.opacity(0.14), dark: Color.white.opacity(0.22)),
                        AdaptiveChrome.dynamic(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.07)),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            ))
            // Layered shadow: contact line seats the panel; the deep soft one lifts it off the
            // canvas. Scaled by `elevation` so repeated cards can float quietly.
            .shadow(color: .black.opacity((isDark ? 0.30 : 0.08) * elevation), radius: 3, y: 1)
            .shadow(color: .black.opacity((isDark ? 0.48 : 0.15) * elevation),
                    radius: 18 * max(elevation, 0.45), y: 8 * max(elevation, 0.45))
    }
}

extension View {
    /// Applies the floating-panel chrome (see SearxlyFloatingPanelStyle). The sidebar, knowledge
    /// panel, and Settings section cards share this so "the floating look" is one definition.
    func searxlyFloatingPanel(cornerRadius: CGFloat = 18,
                              scheme: ColorScheme? = nil,
                              surface: Color? = nil,
                              elevation: CGFloat = 1) -> some View {
        modifier(SearxlyFloatingPanelStyle(cornerRadius: cornerRadius,
                                           schemeOverride: scheme,
                                           surface: surface,
                                           elevation: elevation))
    }
}
