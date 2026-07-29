//
//  HomeAmbientBackground.swift
//  Searxly
//
//  Shared starfield + sunlight glow behind the pure home state (header + hero).
//
//  Searxly Maximum's canvas is pitch black app-wide (AdaptiveChrome.canvasDark). What that means here
//  is that nothing gets painted on top of it — no glow pools, no vignette, no stars. The only light on
//  the Maximum home is the wordmark's own ember glow, which is the point: on a black canvas it has
//  nothing to compete with. It's the look the Maximum activation gate already commits to, so the first
//  screen a buyer sees and the one they open every day after match. The base app keeps its ambient hero.
//

import SwiftUI

struct HomeAmbientBackground: View {
    let glassEnabled: Bool
    let homeStarsEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    /// Maximum's canvas is already pitch black (AdaptiveChrome.canvasDark); what this gates is
    /// everything painted ON it — the glow pools, the vignette, the stars — because any of them would
    /// lift the hero off the black and undo the point.
    private var isMaximumDarkCanvas: Bool { Edition.isMaximum && colorScheme == .dark }

    var body: some View {
        ZStack {
            AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled)
                .ignoresSafeArea()

            if !isMaximumDarkCanvas {
                if glassEnabled {
                    if colorScheme == .dark {
                        RadialGradient(
                            colors: [
                                AdaptiveChrome.fill(colorScheme, dark: 0.06),
                                .clear
                            ],
                            center: .center,
                            startRadius: 60,
                            endRadius: 520
                        )
                        .allowsHitTesting(false)

                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.09),
                                Color.white.opacity(0.035),
                                .clear
                            ],
                            center: UnitPoint(x: 0.5, y: 0.30),
                            startRadius: 24,
                            endRadius: 400
                        )
                        .allowsHitTesting(false)
                    } else {
                        // Light: the paper canvas sits just under pure white, so a strong white pool
                        // reads as soft sunlight on the hero (white-on-white at low opacity is invisible).
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.85),
                                Color.white.opacity(0.3),
                                .clear
                            ],
                            center: UnitPoint(x: 0.5, y: 0.30),
                            startRadius: 24,
                            endRadius: 430
                        )
                        .allowsHitTesting(false)
                    }
                }

                if homeStarsEnabled && !Edition.isMaximum {
                    HomeStarfield(enabled: true)
                }

                if glassEnabled {
                    RadialGradient(
                        colors: [
                            .clear,
                            Color.black.opacity(colorScheme == .dark ? 0.22 : 0.075)
                        ],
                        center: .center,
                        startRadius: 280,
                        endRadius: 720
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
