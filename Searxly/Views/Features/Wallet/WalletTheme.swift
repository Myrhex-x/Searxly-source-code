//
//  WalletTheme.swift
//  Searxly
//
//  Single source of truth for the wallet's look: a premium, monochrome "black" palette that
//  matches the rest of Searxly (AdaptiveChrome.canvasDark). Every wallet panel, sheet, card,
//  field, and stroke draws from these tokens so the whole feature reads as one cohesive surface.
//
//  Brand rule (see the black_white memory): monochrome only. Color is reserved for *meaning* —
//  green for positive / live, red for negative / destructive, amber for a genuine warning.
//

import SwiftUI

enum WalletTheme {

    // MARK: - Canvas (sheet / panel backgrounds)

    /// The deep premium near-black used for the home hero, sidebar, and main chrome. Reusing the
    /// exact app canvas makes the wallet feel native to Searxly rather than a bolted-on dark sheet.
    static let canvas = Color(red: 0.043, green: 0.043, blue: 0.051)
    /// Very slightly lifted canvas for a band that needs to separate from the base (e.g. the
    /// balance summary) without a hard divider.
    static let canvasRaised = Color(red: 0.062, green: 0.062, blue: 0.070)

    // MARK: - Surfaces (cards, rows, inputs) — translucent so the canvas reads through

    static let surface        = Color.white.opacity(0.05)    // cards / grouped rows
    static let surfaceField    = Color.white.opacity(0.06)    // text fields / inputs
    static let surfaceStrong   = Color.white.opacity(0.08)    // secondary buttons / chips
    static let surfaceSelected = Color.white.opacity(0.14)    // selected segment / chip

    // MARK: - Lines

    static let hairline       = Color.white.opacity(0.08)    // card strokes
    static let hairlineStrong = Color.white.opacity(0.14)    // emphasized strokes / focused field
    static let divider        = Color.white.opacity(0.07)

    // MARK: - Text (monochrome ramp)

    static let textPrimary    = Color.white
    static let textSecondary  = Color(white: 0.62)
    static let textTertiary   = Color(white: 0.42)
    static let textFaint      = Color(white: 0.30)

    // MARK: - Semantic (the only color allowed, and only for meaning)

    static let positive = SERPDesign.accentGreen
    static let negative = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let warning  = Color(red: 1.0, green: 0.62, blue: 0.28)

    // MARK: - Geometry

    static let radiusCard: CGFloat  = 18
    static let radiusInner: CGFloat = 12
    static let radiusField: CGFloat = 10

    // MARK: - Primary (white) action button helper

    /// The wallet's primary CTA is a solid white pill with black text — the consistent
    /// "confirm / connect / send" affordance across every sheet.
    static func primaryFill(enabled: Bool) -> Color { enabled ? .white : Color.white.opacity(0.12) }
    static func primaryText(enabled: Bool) -> Color { enabled ? .black : Color(white: 0.34) }
}

// MARK: - Reusable card background

extension View {
    /// Standard wallet card: a flat translucent surface, continuous corners, no border (Phantom-style).
    func walletCard(radius: CGFloat = WalletTheme.radiusCard) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(WalletTheme.surface))
    }

    /// The wallet's liquid-glass card — REAL macOS Liquid Glass (`.glassEffect`) over a faint tint,
    /// with a hairline edge, a top sheen, and a soft drop shadow for lift. The one surface treatment
    /// every panel, row, and sheet uses, so the whole wallet reads as one cohesive glass material.
    /// Falls back to a flat translucent fill when the user turns Liquid Glass down in Settings.
    func walletGlass(radius: CGFloat = WalletTheme.radiusInner,
                     fill: Color = WalletTheme.surface,
                     stroke: Color = WalletTheme.hairline) -> some View {
        modifier(WalletGlassModifier(radius: radius, fill: fill, stroke: stroke))
    }
}

/// Backing modifier for `walletGlass`. A struct (not an inline modifier chain) so it can read the
/// user's "Reduce Liquid Glass" setting and drop the real glass layer when they've asked for it.
private struct WalletGlassModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let stroke: Color
    @AppStorage("reduceLiquidGlass") private var reduceLiquidGlass = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                if reduceLiquidGlass {
                    shape.fill(fill)
                } else {
                    shape.fill(fill)
                        .glassEffect(.regular, in: shape)
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                }
            }
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .overlay(
                // Glass edge: a brighter hairline along the top that fades downward.
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.20), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            )
    }
}

// MARK: - Glass card container

/// A padded liquid-glass card. Compose section content inside; the card owns the material so callers
/// only describe their content (never repeat the background/border/sheen boilerplate).
struct WalletGlassCard<Content: View>: View {
    var radius: CGFloat = WalletTheme.radiusInner
    var padding: CGFloat = 14
    var fill: Color = WalletTheme.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .walletGlass(radius: radius, fill: fill)
    }
}

// MARK: - Section header

/// A section title row: optional leading glyph, bold title, and an optional small caption chip on the
/// right — the exact header rhythm used by the VPN popup, reused across every wallet surface.
struct WalletSectionHeader: View {
    let title: String
    var systemImage: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WalletTheme.textSecondary)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WalletTheme.textPrimary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(WalletTheme.surfaceStrong, in: Capsule())
            }
        }
    }
}

// MARK: - Buttons (the wallet's two CTA affordances)

/// Primary action: a solid white pill with black text — the consistent confirm/connect/send button.
struct WalletPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(WalletTheme.primaryText(enabled: enabled))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(WalletTheme.primaryFill(enabled: enabled),
                        in: RoundedRectangle(cornerRadius: WalletTheme.radiusField + 1, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Secondary action: a glass pill (translucent fill + hairline). Destructive role tints the label red.
struct WalletSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var enabled: Bool = true
    let action: () -> Void

    @State private var hover = false
    private var foreground: Color { role == .destructive ? WalletTheme.negative : WalletTheme.textPrimary }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .walletGlass(radius: WalletTheme.radiusField + 1,
                         fill: hover && enabled ? WalletTheme.surfaceSelected : WalletTheme.surfaceStrong)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { h in DispatchQueue.main.async { hover = h } }
    }
}

/// A round glass icon button — the header affordance (lock / close / refresh / back-as-needed).
struct WalletGlassIconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WalletTheme.textSecondary)
                .frame(width: size, height: size)
                .background(WalletTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Selectable chip (segment)

/// A selectable glass chip: white fill + black text when selected, glass otherwise. Used for token
/// pickers, plan/speed segments, and any "pick one" row — same shape as the VPN popup's plan chips.
struct WalletGlassChip: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.black.opacity(0.65) : WalletTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Color.black : WalletTheme.textPrimary)
            .background(selected ? Color.white : WalletTheme.surface,
                        in: RoundedRectangle(cornerRadius: WalletTheme.radiusField, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WalletTheme.radiusField, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
