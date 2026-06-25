//
//  OnboardingSecurityStep.swift
//  Searxly
//
//  The one interactive step. Privacy is presented as a single, clear superset ladder
//  (Standard → Encrypted → Maximum) so the choices stop overlapping, and App Lock is a
//  real on/off toggle.
//

import AppKit
import SwiftUI

/// A clear, tiered privacy level. Each tier is a superset of the previous one.
enum OnboardingPrivacyLevel: String, CaseIterable, Identifiable {
    case standard
    case encrypted
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:  return "Standard"
        case .encrypted: return "Encrypted"
        case .maximum:   return "Maximum"
        }
    }

    var icon: String {
        switch self {
        case .standard:  return "hand.raised.fill"
        case .encrypted: return "lock.shield.fill"
        case .maximum:   return "eye.slash.fill"
        }
    }

    var badge: String? {
        self == .encrypted ? "Recommended" : nil
    }

    /// One-line summary that makes the ladder explicit.
    var tagline: String {
        switch self {
        case .standard:
            return "Private tabs and no history. Simple and fast."
        case .encrypted:
            return "Everything in Standard, plus your data is encrypted on this Mac."
        case .maximum:
            return "Everything in Encrypted, plus cookies cleared now and Local AI off."
        }
    }

    /// The concrete checklist shown when the tier is selected.
    var features: [String] {
        switch self {
        case .standard:
            return ["Every new tab is private", "Browsing history off"]
        case .encrypted:
            return ["Every new tab is private", "Browsing history off",
                    "Saved data encrypted (AES-256)", "Recovery code generated"]
        case .maximum:
            return ["Every new tab is private", "Browsing history off",
                    "Saved data encrypted (AES-256)", "Recovery code generated",
                    "Existing cookies & cache cleared", "Local AI turned off"]
        }
    }

    var includesEncryption: Bool { self != .standard }
}

struct OnboardingSecurityStep: View {
    @Binding var selectedLevel: OnboardingPrivacyLevel?
    @Binding var recoveryCode: String?
    @Binding var encryptionSetupError: String?
    @Binding var showRecoveryCopied: Bool
    @Binding var showRecoveryDownloaded: Bool
    @Binding var recoveryDownloadError: String?
    @Binding var isSavingRecoveryFile: Bool

    @Binding var appLockEnabled: Bool
    @Binding var isPerformingAppLockAuth: Bool
    @Binding var appLockSetupError: String?

    let onSelectLevel: (OnboardingPrivacyLevel) -> Void
    let onToggleAppLock: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            OnboardingStepHero(
                icon: "slider.horizontal.3",
                title: "Choose your protection level",
                subtitle: "Each level builds on the one before it. You can change any of this later in Settings."
            )

            VStack(spacing: 11) {
                ForEach(OnboardingPrivacyLevel.allCases) { level in
                    levelCard(level)
                }
            }

            if let encryptionSetupError {
                Text(encryptionSetupError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            OnboardingFlatDivider()

            appLockRow

            if let appLockSetupError {
                Text(appLockSetupError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .animation(OnboardingStyle.cardSpring, value: selectedLevel)
    }

    // MARK: - Level card

    private func levelCard(_ level: OnboardingPrivacyLevel) -> some View {
        let isSelected = selectedLevel == level

        // The selectable header is its own Button. The expanded content (which contains the
        // recovery Copy/Download buttons) lives OUTSIDE that button — nesting buttons breaks
        // their taps on macOS.
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                onSelectLevel(level)
            } label: {
                headerRow(level, isSelected: isSelected)
            }
            .buttonStyle(OnboardingPressableButtonStyle())

            if isSelected {
                expandedContent(level)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(OnboardingButtonCardBackground(isSelected: isSelected))
    }

    private func headerRow(_ level: OnboardingPrivacyLevel, isSelected: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: level.icon)
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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(level.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                    if let badge = level.badge {
                        Text(badge.uppercased())
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)))
                    }
                }
                Text(level.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            checkCircle(isSelected: isSelected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func expandedContent(_ level: OnboardingPrivacyLevel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(level.features, id: \.self) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.8))
                            .frame(width: 14)
                        Text(feature)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }

            // Recovery code lives inside the tier it belongs to, so it's clear that BOTH
            // Encrypted and Maximum generate one.
            if level.includesEncryption, let code = recoveryCode {
                encryptionRecoveryCard(code: code)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 15)
    }

    @ViewBuilder
    private func checkCircle(isSelected: Bool) -> some View {
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

    // MARK: - App Lock toggle

    private var appLockRow: some View {
        Button {
            guard !isPerformingAppLockAuth else { return }
            onToggleAppLock(!appLockEnabled)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "faceid")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(appLockEnabled ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(AdaptiveChrome.fill(colorScheme, dark: appLockEnabled ? 0.14 : 0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: appLockEnabled ? 0.24 : 0.11), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("App Lock")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("OPTIONAL")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)))
                    }
                    Text("Require Touch ID or your Mac password every time Searxly opens.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if isPerformingAppLockAuth {
                    ProgressView().controlSize(.small)
                } else {
                    OnboardingToggleKnob(isOn: appLockEnabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: OnboardingStyle.minTapHeight)
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.buttonCardCornerRadius, style: .continuous))
        }
        .buttonStyle(OnboardingCardButtonStyle(isSelected: appLockEnabled))
    }

    // MARK: - Recovery code card

    private func encryptionRecoveryCard(code: String) -> some View {
        OnboardingInsetCard {
            VStack(alignment: .center, spacing: 12) {
                Text("Your recovery code")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)

                Text("Save this somewhere safe. You'll need it if your Keychain is reset or you move to a new Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(String(repeating: "•", count: 28))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("Hidden on screen for security. Copy or download to save it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    OnboardingActionCard(title: showRecoveryCopied ? "Copied" : "Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        showRecoveryCopied = true
                        showRecoveryDownloaded = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(2200))
                            showRecoveryCopied = false
                        }
                    }
                    .frame(maxWidth: .infinity)

                    OnboardingActionCard(
                        title: isSavingRecoveryFile ? "Saving…" : (showRecoveryDownloaded ? "Saved" : "Download"),
                        systemImage: "arrow.down.doc",
                        disabled: isSavingRecoveryFile
                    ) {
                        Task { @MainActor in
                            isSavingRecoveryFile = true
                            recoveryDownloadError = nil
                            if await PrivacyManager.shared.saveRecoveryCodeToFile(code) != nil {
                                showRecoveryDownloaded = true
                                showRecoveryCopied = false
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(2600))
                                    showRecoveryDownloaded = false
                                }
                            } else {
                                recoveryDownloadError = "Save cancelled or the file could not be written."
                            }
                            isSavingRecoveryFile = false
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                if let recoveryDownloadError {
                    Text(recoveryDownloadError)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// A small monochrome on/off knob (the system switch is tinted, which would break brand).
struct OnboardingToggleKnob: View {
    let isOn: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(AdaptiveChrome.fill(colorScheme, dark: isOn ? 0.30 : 0.10))
                .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.18), lineWidth: 1))
                .frame(width: 44, height: 26)
            Circle()
                .fill(isOn ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AdaptiveChrome.fill(colorScheme, dark: 0.55)))
                .frame(width: 20, height: 20)
                .padding(.horizontal, 3)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: 44, height: 26)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOn)
    }
}
