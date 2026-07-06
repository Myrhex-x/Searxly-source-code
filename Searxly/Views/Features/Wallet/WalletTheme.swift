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

    // MARK: - Canvas (sheet / panel backgrounds) — adaptive: near-black in dark, white in light

    /// Dark: the deep premium near-black shared with the home hero and main chrome. Light: a white
    /// panel matching the other adaptive popovers. Reusing the app language keeps the wallet feeling
    /// native to Searxly rather than a bolted-on sheet.
    static let canvas = AdaptiveChrome.dynamic(
        light: .white,
        dark: Color(red: 0.043, green: 0.043, blue: 0.051)
    )
    /// Very slightly lifted canvas for a band that needs to separate from the base (e.g. the
    /// balance summary) without a hard divider.
    static let canvasRaised = AdaptiveChrome.dynamic(
        light: Color(red: 0.968, green: 0.968, blue: 0.973),
        dark: Color(red: 0.062, green: 0.062, blue: 0.070)
    )

    // MARK: - Surfaces (cards, rows, inputs) — translucent so the canvas reads through

    static let surface         = AdaptiveChrome.dynamic(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.05))
    static let surfaceField    = AdaptiveChrome.dynamic(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.06))
    static let surfaceStrong   = AdaptiveChrome.dynamic(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08))
    static let surfaceSelected = AdaptiveChrome.dynamic(light: Color.black.opacity(0.11), dark: Color.white.opacity(0.14))

    // MARK: - Lines

    static let hairline       = AdaptiveChrome.dynamic(light: Color.black.opacity(0.085), dark: Color.white.opacity(0.08))
    static let hairlineStrong = AdaptiveChrome.dynamic(light: Color.black.opacity(0.16), dark: Color.white.opacity(0.14))
    static let divider        = AdaptiveChrome.dynamic(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.07))

    // MARK: - Text (monochrome ramp)

    static let textPrimary   = AdaptiveChrome.dynamic(light: Color(white: 0.09), dark: .white)
    static let textSecondary = AdaptiveChrome.dynamic(light: Color(white: 0.33), dark: Color(white: 0.62))
    static let textTertiary  = AdaptiveChrome.dynamic(light: Color(white: 0.48), dark: Color(white: 0.42))
    static let textFaint     = AdaptiveChrome.dynamic(light: Color(white: 0.62), dark: Color(white: 0.30))

    // MARK: - Semantic (the only color allowed, and only for meaning; deepened for light)

    static let positive = SERPDesign.accentGreen
    static let negative = AdaptiveChrome.dynamic(
        light: Color(red: 0.78, green: 0.22, blue: 0.22),
        dark: Color(red: 1.0, green: 0.42, blue: 0.42)
    )
    static let warning = AdaptiveChrome.dynamic(
        light: Color(red: 0.8, green: 0.48, blue: 0.1),
        dark: Color(red: 1.0, green: 0.62, blue: 0.28)
    )

    // MARK: - Geometry

    static let radiusCard: CGFloat  = 18
    static let radiusInner: CGFloat = 12
    static let radiusField: CGFloat = 10

    /// The single horizontal gutter for the wallet home, so the header, balance, actions, and token
    /// list all align to one column (previously a mix of 16/18/22).
    static let pagePadding: CGFloat = 16

    // MARK: - Primary ("ink") action button helper

    /// The wallet's primary CTA is a solid ink pill — white-on-black in dark mode, black-on-white in
    /// light — the consistent "confirm / connect / send" affordance across every sheet.
    static let ink   = AdaptiveChrome.dynamic(light: Color(white: 0.12), dark: .white)
    static let onInk = AdaptiveChrome.dynamic(light: .white, dark: .black)

    static func primaryFill(enabled: Bool) -> Color {
        enabled ? ink : AdaptiveChrome.dynamic(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.12))
    }
    static func primaryText(enabled: Bool) -> Color {
        enabled ? onInk : AdaptiveChrome.dynamic(light: Color(white: 0.62), dark: Color(white: 0.34))
    }
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
                        .searxlyGlass(.regular, in: shape)
                        .shadow(
                            color: AdaptiveChrome.dynamic(
                                light: Color.black.opacity(0.10),
                                dark: Color.black.opacity(0.22)
                            ),
                            radius: 8, y: 3
                        )
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
                        .foregroundStyle(selected ? WalletTheme.onInk.opacity(0.65) : WalletTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? WalletTheme.onInk : WalletTheme.textPrimary)
            .background(selected ? WalletTheme.ink : WalletTheme.surface,
                        in: RoundedRectangle(cornerRadius: WalletTheme.radiusField, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WalletTheme.radiusField, style: .continuous)
                    .strokeBorder(selected ? Color.clear : WalletTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transaction progress (shared by Swap / Send)

/// Narrated transaction progress: the stages already passed with checkmarks, plus the one running
/// now with a spinner. Drives the "is it frozen?" anxiety out of multi-second signing/broadcast
/// flows — the swap and send screens both render their stage callbacks through this.
struct WalletStageList: View {
    let done: [String]
    let current: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(done.enumerated()), id: \.offset) { _, label in
                row(label, done: true)
            }
            if !current.isEmpty { row(current, done: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .walletGlass(radius: 14, fill: WalletTheme.surfaceField)
    }

    private func row(_ label: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(WalletTheme.textPrimary)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                }
            }
            .frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 12, weight: done ? .regular : .medium))
                .foregroundStyle(done ? WalletTheme.textSecondary : WalletTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)\(done ? ", done" : ", in progress")")
    }
}

/// Status line under a "submitted" screen: spinner while the transaction is in the mempool, then
/// the definitive on-chain outcome. `nil` = still confirming; `.pending` = polling gave up (the tx
/// is still in the mempool — Activity keeps tracking it). Green is a status signal, allowed.
struct WalletTxConfirmationLine: View {
    let status: WalletNetwork.ReceiptStatus?
    let chainName: String
    var failureText = "The transaction failed on-chain (reverted) — only the network fee was spent."

    var body: some View {
        switch status {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Confirming on \(chainName)…")
                    .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            }
        case .success:
            Label("Confirmed on \(chainName)", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(WalletTheme.positive)
        case .failed:
            Text(failureText)
                .font(.system(size: 11)).foregroundStyle(WalletTheme.negative)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        case .pending:
            Text("Still confirming — you can track it in Activity.")
                .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
        }
    }
}
