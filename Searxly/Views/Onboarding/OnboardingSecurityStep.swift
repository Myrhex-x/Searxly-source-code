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
        case .standard:  return "Normal"
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
        switch self {
        case .standard:  return nil
        case .encrypted: return "Recommended"
        case .maximum:   return "For professionals"
        }
    }

    /// The recommended tier gets the prominent (filled) badge; the professional tier a subtle outline.
    var badgeIsProminent: Bool { self == .encrypted }

    /// One-line summary that makes the ladder explicit.
    var tagline: String {
        switch self {
        case .standard:
            return "Private tabs and no history. Simple and fast."
        case .encrypted:
            return "Everything in Standard, plus your data is encrypted on this Mac."
        case .maximum:
            return "Everything in Encrypted, plus your IP is hidden (VPN or Tor) and your browser fingerprint is scrambled."
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
                    "IP hidden via VPN or Tor — traffic blocked if neither is up",
                    "Browser fingerprint scrambled",
                    "Cookies & cache cleared, Local AI off"]
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

    @Bindable private var tor = TorManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            OnboardingStepHero(
                icon: "slider.horizontal.3",
                title: "Choose your protection level",
                subtitle: "Each level builds on the one before. Encrypted is right for most people; Maximum is for professionals who accept that some sites may break."
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

            OnboardingFlatDivider()

            torRow
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
                    badgeView(level)
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

    /// Tier badge with two styles: the recommended tier is a filled (prominent) capsule; the
    /// professional tier is a subtle outlined capsule. Normal has no badge.
    @ViewBuilder
    private func badgeView(_ level: OnboardingPrivacyLevel) -> some View {
        if let badge = level.badge {
            if level.badgeIsProminent {
                Text(badge.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary))
            } else {
                Text(badge.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.08)))
                    .overlay(Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.20), lineWidth: 1))
            }
        }
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

    // MARK: - Tor row (optional onion routing; off by default)

    private var torRow: some View {
        Button {
            tor.isEnabled.toggle()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tor.isEnabled ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(AdaptiveChrome.fill(colorScheme, dark: tor.isEnabled ? 0.14 : 0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: tor.isEnabled ? 0.24 : 0.11), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Tor for .onion sites")
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
                    Text("Open .onion hidden services over Tor with your IP hidden. Only onion tabs are routed; your normal browsing is untouched. You can change this anytime in Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                OnboardingToggleKnob(isOn: tor.isEnabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: OnboardingStyle.minTapHeight)
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.buttonCardCornerRadius, style: .continuous))
        }
        .buttonStyle(OnboardingCardButtonStyle(isSelected: tor.isEnabled))
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

/// A dedicated, deliberate confirmation shown when the user picks Maximum during onboarding. Maximum is
/// the only level that can change how sites work (fingerprint farbling / screen spoofing) and that gates
/// traffic behind VPN/Tor (search rides Tor in Tor mode — slower, some engines may block Tor exits), so
/// we spell out the trade-offs and make the user opt in — or go back — rather than applying it on a
/// single tap.
struct MaximumPrivacyConfirmView: View {
    let onConfirm: (MaxProtection) -> Void
    let onGoBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var protection: MaxProtection = .tor

    // (icon, title, detail)
    private let points: [(String, String, String)] = [
        ("eye.slash.fill", "Your IP is hidden — or you go offline",
         "Browsing is routed through the Searxly VPN or Tor. If neither is connected, Searxly blocks traffic rather than leaking your real IP. That's the kill switch — by design."),
        ("shield.lefthalf.filled", "Your fingerprint is scrambled",
         "Canvas, audio, WebGL and screen signals are randomized so sites can't easily re-identify you. A few sites may render or behave oddly as a result."),
        ("magnifyingglass", "Search stays protected",
         "With the VPN, search runs at full speed through the tunnel. In Tor mode, your searches exit through Tor instead — expect slower results, and some sources may refuse Tor."),
        ("trash", "A fresh, quiet start",
         "Existing cookies and cache are cleared, history stays off, and on-device AI is turned off.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    OnboardingStepHero(
                        icon: "eye.slash.fill",
                        title: "Turn on Maximum Privacy?",
                        subtitle: "The strongest level — and the only one that can change how some sites work. Here's exactly what it does."
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(points, id: \.0) { point in
                            HStack(alignment: .top, spacing: 13) {
                                Image(systemName: point.0)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(AdaptiveChrome.fill(colorScheme, dark: 0.10))
                                    )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(point.1)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(point.2)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: 520)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("HIDE MY IP WITH")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        protectionCard(.vpn)
                        protectionCard(.tor)
                    }
                    .frame(maxWidth: 520)

                    Text("You can switch back to Normal or Encrypted anytime in Settings → Privacy.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: onGoBack) {
                    Text("Go back")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.22), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button { onConfirm(protection) } label: {
                    Text("Enable Maximum Privacy")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Color.primary))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        // Default to the option that actually works for this user: VPN if they hold a pass (covers
        // search too), otherwise Tor (free, works without paying — search stays off).
        .onAppear { protection = ManagedVPNService.shared.hasActivePass ? .vpn : .tor }
    }

    private func protectionCard(_ option: MaxProtection) -> some View {
        let isSel = protection == option
        let needsPass = (option == .vpn) && !ManagedVPNService.shared.hasActivePass
        return Button {
            protection = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AdaptiveChrome.fill(colorScheme, dark: isSel ? 0.14 : 0.07))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if needsPass {
                            Text("NEEDS PASS")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.10)))
                        }
                    }
                    Text(option.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSel ? .primary : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: isSel ? 0.10 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: isSel ? 0.28 : 0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
