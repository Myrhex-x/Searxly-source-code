//
//  SettingsLayout.swift
//  Searxly
//
//  The Settings design system — rebuilt from scratch in the Searxly monochrome-premium language.
//  Every Settings pane composes only from these primitives, so this one file defines the entire
//  look of the Settings surface: near-black canvas, hairline-bordered cards, monochrome controls.
//
//  Layout contract (important): primitives DO NOT impose their own width or page padding. The
//  Settings shell (`SettingsView`) wraps every pane in a single centered reading column. That keeps
//  all panes perfectly aligned and prevents the "content jammed to one side" problem.
//
//  Brand rule: white is the primary/active color. Green (and other hues) are reserved for genuine
//  status — Locked / Ready / Protected / On — never decoration.
//

import SwiftUI

// MARK: - Theme tokens

enum SettingsTheme {
    /// Page background.
    static let canvas         = Color(red: 0.039, green: 0.039, blue: 0.047)
    /// Sidebar / header chrome — a hair lighter than the canvas.
    static let canvasRaised   = Color(red: 0.071, green: 0.071, blue: 0.082)

    /// Card surfaces (translucent white over the canvas so they read at any depth).
    static let card           = Color.white.opacity(0.038)
    static let cardStrong      = Color.white.opacity(0.072)

    /// Hairline strokes.
    static let hairline        = Color.white.opacity(0.07)
    static let hairlineStrong  = Color.white.opacity(0.13)

    /// Text ramp.
    static let textPrimary     = Color.white
    static let textSecondary   = Color(white: 0.62)
    static let textTertiary    = Color(white: 0.40)

    /// Status accents (status only — never decorative).
    static let green           = SERPDesign.accentGreen
    static let danger          = Color(red: 1.0, green: 0.45, blue: 0.45)
    static let warning         = Color(red: 0.98, green: 0.66, blue: 0.32)

    /// Normalizes a caller-supplied tint. `.secondary` is treated as a neutral (white) accent so
    /// informational callouts stay monochrome instead of picking up a system gray.
    static func resolve(_ tint: Color) -> Color {
        tint == .secondary ? .white : tint
    }
}

// MARK: - Monochrome toggle

/// The single switch style for all of Settings. ON = solid white track, dark knob. OFF = dim track.
struct PremiumToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 10)
            track(configuration)
        }
    }

    private func track(_ configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
                .fill(configuration.isOn ? Color.white : Color.white.opacity(0.12))
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(configuration.isOn ? 0 : 0.16), lineWidth: 1)
                )
                .frame(width: 40, height: 24)
            Circle()
                .fill(configuration.isOn ? Color.black.opacity(0.88) : Color.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .padding(.horizontal, 3)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        }
        .frame(width: 40, height: 24)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                configuration.isOn.toggle()
            }
        }
    }
}

// MARK: - Pane shell

/// A settings pane. Intentionally layout-neutral: spacing only, no width or page padding (the shell
/// owns the reading column). Compose `SettingsPaneHeader` + `SettingsSection`s inside.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsPaneHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(SettingsTheme.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Sections

/// A titled group of rows rendered inside a hairline card.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(SettingsTheme.hairline, lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, 1)
            }
        }
    }
}

/// Inset divider for separating rows inside a section card.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsTheme.hairline)
            .frame(height: 1)
            .padding(.vertical, 1)
    }
}

// MARK: - Rows

struct SettingsToggleRow: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool
    var badge: String? = nil
    var badgeTint: Color = .white      // "On" reads monochrome, matching the white toggle

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    if let badge {
                        SettingsBadge(text: badge, tint: badgeTint)
                    }
                }
            }
            .toggleStyle(PremiumToggleStyle())

            if let description {
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 48)   // keep copy clear of the switch column
            }
        }
    }
}

struct SettingsPickerRow<Selection: Hashable, Content: View>: View {
    let title: String
    var description: String? = nil
    @Binding var selection: Selection
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)

            content
                .tint(.white)

            if let description {
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsLabeledField: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let field: () -> AnyView

    init(title: String, description: String? = nil, @ViewBuilder field: @escaping () -> some View) {
        self.title = title
        self.description = description
        self.field = { AnyView(field()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)

            field()

            if let description {
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Callout

/// An informational / status banner. Neutral by default; pass a status `tint` for warnings or
/// confirmations. `.secondary` resolves to a neutral white treatment.
struct SettingsCallout: View {
    let title: String
    let message: String
    var tint: Color = SettingsTheme.warning
    var systemImage: String = "info.circle.fill"

    private var accent: Color { SettingsTheme.resolve(tint) }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)

                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: - Actions

/// A prominent tappable navigation/shortcut row — monochrome by design. `tint` is accepted for
/// source compatibility but only nudges the leading glyph; the row itself stays white-on-near-black.
struct SettingsProminentAction: View {
    let title: String
    let systemImage: String
    var tint: Color = SettingsTheme.green
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 30, height: 30)
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                }

                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SettingsTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hover ? SettingsTheme.cardStrong : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(hover ? SettingsTheme.hairlineStrong : SettingsTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in DispatchQueue.main.async { hover = h } }
    }
}

// MARK: - Inset panel & chips

/// A subtle nested panel for grouping related controls inside a section card.
struct SettingsInsetPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsTheme.hairline, lineWidth: 1)
            )
    }
}

/// A compact pill button used for secondary actions (Restart, View log, Open folder…).
struct SettingsActionChip: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var disabled: Bool = false
    let action: () -> Void

    @State private var hover = false

    private var foreground: Color {
        role == .destructive ? SettingsTheme.danger : SettingsTheme.textPrimary
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Color.white.opacity(hover && !disabled ? 0.10 : 0.05),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hover && !disabled ? SettingsTheme.hairlineStrong : SettingsTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { h in DispatchQueue.main.async { hover = h } }
    }
}

/// Lays chips out in an adaptive grid so a row of actions wraps cleanly.
struct SettingsActionChipGrid<Content: View>: View {
    @ViewBuilder let content: Content

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            content
        }
    }
}
