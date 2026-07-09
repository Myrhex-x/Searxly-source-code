//
//  GlassButtonStyles.swift
//  Searxly
//
//  Shared glass button / pill / icon styles used across the SERP, media grids, sidebar, and wallet.
//  Uses the app's existing glassEnabled / reduceLiquidGlass conventions. Hover lift, spring press,
//  consistent sizing and high-quality tap targets.
//

import SwiftUI

// MARK: - Glass Pill Button Style (primary for chips, actions, model pills)

struct GlassPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    var isProminent: Bool = false      // stronger accent / send-like
    var tint: Color? = nil
    var glassEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(background(for: configuration.isPressed))
            .overlay(
                Capsule()
                    .strokeBorder(borderColor(for: configuration.isPressed), lineWidth: glassEnabled ? 0.7 : 0.5)
            )
            .foregroundStyle(foreground(for: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
            .shadow(
                color: AdaptiveChrome.shadow(
                    colorScheme,
                    darkOpacity: configuration.isPressed ? 0.06 : (glassEnabled ? 0.12 : 0.06)
                ),
                radius: configuration.isPressed ? 2 : (glassEnabled ? 6 : 2),
                x: 0,
                y: configuration.isPressed ? 1 : 3
            )
    }

    private func background(for pressed: Bool) -> some View {
        let base = glassEnabled
            ? (isProminent ? Color.accentColor.opacity(0.18) : AdaptiveChrome.fill(colorScheme, dark: 0.06))
            : (isProminent ? Color.accentColor.opacity(0.22) : AdaptiveChrome.fill(colorScheme, dark: 0.035))

        let pressedOverlay = pressed ? AdaptiveChrome.pressedOverlay(colorScheme) : Color.clear

        return Capsule()
            .fill(base)
            .overlay(pressedOverlay)
            .background(
                Capsule()
                    .fill(.thinMaterial)
                    .opacity(glassEnabled ? (isProminent ? 0.35 : 0.6) : 0.85)
            )
    }

    private func borderColor(for pressed: Bool) -> Color {
        if isProminent {
            return (tint ?? .accentColor).opacity(pressed ? 0.6 : (glassEnabled ? 0.45 : 0.3))
        }
        return AdaptiveChrome.border(colorScheme, dark: pressed ? 0.16 : (glassEnabled ? 0.10 : 0.06))
    }

    private func foreground(for pressed: Bool) -> Color {
        if isProminent {
            return (tint ?? .accentColor).opacity(pressed ? 0.85 : 1.0)
        }
        return .primary.opacity(pressed ? 0.85 : 1.0)
    }
}

// MARK: - Glass Icon Button (circle / capsule icons for toolbar-like controls: history, tools, close, paperclip, etc.)

struct GlassIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    var glassEnabled: Bool = true
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.52, weight: .semibold))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(glassEnabled ? .thinMaterial : .regularMaterial)
                    .overlay(
                        Circle()
                            .fill(AdaptiveChrome.fill(
                                colorScheme,
                                dark: configuration.isPressed ? 0.06 : (glassEnabled ? 0.035 : 0.02)
                            ))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                AdaptiveChrome.border(
                                    colorScheme,
                                    dark: configuration.isPressed ? 0.18 : (glassEnabled ? 0.09 : 0.05)
                                ),
                                lineWidth: 0.6
                            )
                    )
            )
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.7 : 0.95))
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .shadow(
                color: AdaptiveChrome.shadow(colorScheme, darkOpacity: glassEnabled ? 0.15 : 0.08),
                radius: configuration.isPressed ? 1 : 4,
                x: 0,
                y: 1
            )
            .animation(.spring(response: 0.18, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - Convenience View Modifiers

extension View {
    func glassPill(isProminent: Bool = false, tint: Color? = nil, glassEnabled: Bool = true) -> some View {
        self.buttonStyle(GlassPillButtonStyle(isProminent: isProminent, tint: tint, glassEnabled: glassEnabled))
    }

    func glassIcon(size: CGFloat = 28, glassEnabled: Bool = true) -> some View {
        self.buttonStyle(GlassIconButtonStyle(glassEnabled: glassEnabled, size: size))
    }
}
