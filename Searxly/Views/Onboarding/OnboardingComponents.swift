//
//  OnboardingComponents.swift
//  Searxly
//

import AppKit
import SwiftUI

// MARK: - Progress

struct OnboardingProgressHeader: View {
    let step: Int

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<OnboardingStyle.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(dotFill(for: index))
                        .frame(width: index == step ? 28 : 7, height: 4)
                        .shadow(
                            color: index == step
                                ? Color.white.opacity(colorScheme == .dark ? 0.4 : 0.1)
                                : .clear,
                            radius: 6
                        )
                        .animation(OnboardingStyle.stepSpring, value: step)
                }
            }

            HStack(spacing: 6) {
                Text(OnboardingStyle.stepLabels[step].uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2.0)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text("\(step + 1) of \(OnboardingStyle.stepCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func dotFill(for index: Int) -> Color {
        if index == step {
            return colorScheme == .dark ? Color.white.opacity(0.95) : Color.primary.opacity(0.85)
        }
        if index < step {
            return AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.44 : 0.32)
        }
        return AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.12 : 0.08)
    }
}

// MARK: - Glass card (scrollable content steps)

struct OnboardingGlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OnboardingStyle.cardCornerRadius, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.09 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingStyle.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.22 : 0.14),
                                AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.08 : 0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: AdaptiveChrome.shadow(colorScheme, darkOpacity: glassEnabled ? 0.45 : 0.18),
                radius: 28,
                y: 10
            )
    }
}

// MARK: - Instruction strip

struct OnboardingInstructionStrip: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Action bar

struct OnboardingActionBar: View {
    var showBack: Bool = false
    var backAction: () -> Void = {}
    var skipTitle: String? = nil
    var skipAction: () -> Void = {}
    var primaryTitle: String
    var primarySystemImage: String? = nil
    var primaryDisabled: Bool = false
    var primaryLoading: Bool = false
    var primaryAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Left: back button (or truly nothing — no placeholder)
            if showBack {
                OnboardingSecondaryButton(title: "Back", systemImage: "chevron.left", action: backAction)
            }

            Spacer(minLength: 0)

            // Right: skip text link + primary CTA
            HStack(spacing: 16) {
                if let skipTitle {
                    Button(action: skipAction) {
                        Text(skipTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: OnboardingStyle.minTapHeight)
                }

                OnboardingCTA(
                    title: primaryTitle,
                    systemImage: primarySystemImage,
                    disabled: primaryDisabled,
                    isLoading: primaryLoading,
                    action: primaryAction
                )
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

// MARK: - Shell

struct OnboardingShell<Content: View>: View {
    let step: Int
    var instruction: String? = nil
    var scrollable: Bool = false
    var showProgress: Bool = false
    var useGlassCard: Bool = true
    var maxContentWidth: CGFloat = OnboardingStyle.contentMaxWidth
    @ViewBuilder let content: Content
    @ViewBuilder let actionBar: () -> OnboardingActionBar

    var body: some View {
        VStack(spacing: 0) {
            if showProgress {
                OnboardingProgressHeader(step: step)
                    .padding(.top, 20)
                    .padding(.bottom, 18)
            }

            Group {
                if useGlassCard {
                    if scrollable {
                        // Card is the fixed outer container; content scrolls inside it
                        OnboardingGlassCard {
                            ScrollView(.vertical, showsIndicators: false) {
                                content
                            }
                        }
                    } else {
                        OnboardingGlassCard { content }
                    }
                } else {
                    if scrollable {
                        ScrollView(.vertical, showsIndicators: false) {
                            content
                        }
                    } else {
                        content
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let instruction {
                OnboardingInstructionStrip(text: instruction)
                    .padding(.top, 14)
            }

            actionBar()
        }
        .frame(maxWidth: maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Button card background

struct OnboardingButtonCardBackground: View {
    var isSelected: Bool = false
    var isPressed: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled

    private var fillOpacity: Double {
        if isPressed { return glassEnabled ? 0.14 : 0.10 }
        if isSelected { return glassEnabled ? 0.12 : 0.08 }
        return glassEnabled ? 0.07 : 0.05
    }

    private var borderOpacity: Double {
        if isSelected { return glassEnabled ? 0.30 : 0.22 }
        return glassEnabled ? 0.14 : 0.10
    }

    var body: some View {
        RoundedRectangle(cornerRadius: OnboardingStyle.buttonCardCornerRadius, style: .continuous)
            .fill(AdaptiveChrome.fill(colorScheme, dark: fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingStyle.buttonCardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? LinearGradient(
                                colors: [
                                    AdaptiveChrome.border(colorScheme, dark: borderOpacity * 1.4),
                                    AdaptiveChrome.border(colorScheme, dark: borderOpacity * 0.6)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [AdaptiveChrome.border(colorScheme, dark: borderOpacity)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? AdaptiveChrome.shadow(colorScheme, darkOpacity: glassEnabled ? 0.30 : 0.12)
                    : .clear,
                radius: isSelected ? 16 : 0,
                y: isSelected ? 6 : 0
            )
    }
}

struct OnboardingCardButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                OnboardingButtonCardBackground(
                    isSelected: isSelected,
                    isPressed: configuration.isPressed
                )
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Compact tappable card for secondary actions (Open folder, Recheck status, etc.)
struct OnboardingActionCard: View {
    let title: String
    var systemImage: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.medium))
                }
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: OnboardingStyle.minTapHeight)
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.buttonCardCornerRadius, style: .continuous))
        }
        .buttonStyle(OnboardingCardButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Non-interactive inset panel (status blocks, recovery code, summary rows).
struct OnboardingInsetCard<Content: View>: View {
    var isSelected: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(OnboardingButtonCardBackground(isSelected: isSelected))
    }
}

// MARK: - Buttons

struct OnboardingPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// High-presence primary CTA — luminous white capsule against the dark cosmic canvas.
struct ChromePrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var disabled: Bool = false
    var isLoading: Bool = false
    var maxWidth: CGFloat = 280
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(labelColor)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.1)
                if let systemImage, !isLoading {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .bold))
                        .offset(x: isHovering && !reduceMotion ? 2.5 : 0)
                        .animation(.easeOut(duration: 0.16), value: isHovering)
                }
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(minWidth: 160, maxWidth: maxWidth, minHeight: 46)
            .background(
                Capsule(style: .continuous)
                    .fill(fillGradient)
                    .shadow(color: glowShadow, radius: isHovering ? 22 : 14)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(topEdge, lineWidth: 0.75)
            )
            .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .disabled(disabled || isLoading)
        .opacity(disabled ? 0.38 : 1)
        .onHover { h in
            guard !disabled, !isLoading else { return }
            withAnimation(.easeOut(duration: 0.16)) { isHovering = h }
        }
    }

    private var labelColor: Color {
        colorScheme == .dark ? AdaptiveChrome.canvasDark : .white
    }

    private var fillGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color.white, Color.white.opacity(0.86)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.primary, Color.primary.opacity(0.82)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var topEdge: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.6), Color.white.opacity(0.0)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var glowShadow: Color {
        guard !disabled else { return .clear }
        return colorScheme == .dark
            ? Color.white.opacity(isHovering ? 0.28 : 0.16)
            : Color.black.opacity(isHovering ? 0.20 : 0.10)
    }
}

struct OnboardingCTA: View {
    let title: String
    var systemImage: String? = nil
    var disabled: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        ChromePrimaryButton(
            title: title,
            systemImage: systemImage,
            disabled: disabled,
            isLoading: isLoading,
            action: action
        )
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: OnboardingStyle.minTapHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 1)
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(OnboardingPressableButtonStyle())
    }
}

// MARK: - Choice row

struct OnboardingChoiceRow: View {
    let title: String
    let subtitle: String
    var icon: String? = nil
    var badge: String? = nil
    let isSelected: Bool
    var trailing: AnyView? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    iconBadge(icon)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10))
                                )
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if let trailing {
                    trailing
                } else {
                    checkCircle
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: OnboardingStyle.minTapHeight)
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.buttonCardCornerRadius, style: .continuous))
        }
        .buttonStyle(OnboardingCardButtonStyle(isSelected: isSelected))
        .animation(OnboardingStyle.cardSpring, value: isSelected)
    }

    @ViewBuilder
    private var checkCircle: some View {
        ZStack {
            Circle()
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: isSelected ? 0 : 0.20), lineWidth: 1.5)
                .frame(width: 20, height: 20)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
    }

    private func iconBadge(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: isSelected ? 0.14 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: isSelected ? 0.24 : 0.11), lineWidth: 1)
                    )
            )
    }
}

struct OnboardingFlatDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(AdaptiveChrome.divider(colorScheme))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

// MARK: - Step hero (for scrollable steps)

struct OnboardingStepHero: View {
    let icon: String
    let title: String
    let subtitle: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.onboardingGlassEnabled) private var glassEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                // Halo
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.20 : 0.12),
                                .clear
                            ],
                            center: .center, startRadius: 0, endRadius: 50
                        )
                    )
                    .frame(width: 110, height: 110)
                    .blur(radius: 8)
                    .opacity(appeared ? 1 : 0)

                // Medallion
                Circle()
                    .fill(AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.10 : 0.07))
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [
                                    AdaptiveChrome.border(colorScheme, dark: 0.28),
                                    AdaptiveChrome.border(colorScheme, dark: 0.06)
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    )
                    .frame(width: 62, height: 62)
                    .shadow(color: AdaptiveChrome.shadow(colorScheme, darkOpacity: 0.35), radius: 14, y: 6)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)

                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.9))
                    .symbolEffect(.pulse, options: .repeating.speed(0.3), isActive: appeared && !reduceMotion)
                    .scaleEffect(appeared ? 1 : 0.5)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

// MARK: - Visual-only reveal (never blocks hit testing)

struct OnboardingVisualReveal: ViewModifier {
    let revealed: Bool
    let reduceMotion: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (revealed ? 0 : 10))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.40).delay(delay),
                value: revealed
            )
    }
}

extension View {
    func onboardingVisualReveal(_ revealed: Bool, reduceMotion: Bool, delay: Double = 0) -> some View {
        modifier(OnboardingVisualReveal(revealed: revealed, reduceMotion: reduceMotion, delay: delay))
    }
}
