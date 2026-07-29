//
//  PasswordVaultLockView.swift
//  Searxly
//
//  Vault unlock overlay — monochrome glass card matching AppLockView.
//

import SwiftUI

struct PasswordVaultLockView: View {
    let glassEnabled: Bool
    let toolbarMaterial: Material
    let onUnlock: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var passphrase = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var cardAppeared = false

    private var vault: PasswordVaultManager { PasswordVaultManager.shared }

    private var protectedLoginLabel: String {
        switch vault.savedLoginCount {
        case 0: return "No logins saved yet"
        case 1: return "1 login protected"
        default: return "\(vault.savedLoginCount) logins protected"
        }
    }

    var body: some View {
        ZStack {
            lockBackdrop

            VStack(spacing: 0) {
                Spacer(minLength: 48)

                lockCard
                    .offset(x: shakeOffset)
                    .scaleEffect(cardAppeared ? 1 : 0.94)
                    .opacity(cardAppeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: cardAppeared)

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: errorMessage) { _, newValue in
            if newValue != nil {
                triggerShake()
            }
        }
        .onAppear {
            cardAppeared = true
            if !vault.useCustomVaultPassphrase, !isUnlocking {
                attemptUnlock()
            }
        }
    }

    // MARK: - Backdrop

    private var lockBackdrop: some View {
        ZStack {
            AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled)
                .ignoresSafeArea()

            if colorScheme == .dark {
                RadialGradient(
                    colors: [Color.white.opacity(0.05), Color.clear],
                    center: .top,
                    startRadius: 24,
                    endRadius: 400
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Card

    private var lockCard: some View {
        VStack(spacing: 26) {
            lockHero
            unlockPanel
            errorBanner
            securityFootnotes
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: 420)
        .background(cardSurface)
        .overlay(cardBorder)
        .shadow(
            color: AdaptiveChrome.shadow(colorScheme, darkOpacity: glassEnabled ? 0.42 : 0.12),
            radius: glassEnabled ? 32 : 16,
            y: 12
        )
    }

    private var lockHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06, light: 0.04))
                    .frame(width: 76, height: 76)
                    .overlay(
                        Circle()
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.14), lineWidth: 1)
                    )

                Image(systemName: vault.useCustomVaultPassphrase ? "lock.shield.fill" : "key.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.72))
                    .symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: !isUnlocking && !reduceMotion)
            }

            VStack(spacing: 6) {
                Text("Password Vault")
                    .font(.title2.weight(.semibold))

                Text(protectedLoginLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(vault.useCustomVaultPassphrase
                     ? "Enter your vault passphrase to view saved logins."
                     : "Authenticate with Touch ID or your Mac login password.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var unlockPanel: some View {
        if vault.useCustomVaultPassphrase {
            VStack(spacing: 12) {
                SecureField("Vault passphrase", text: $passphrase)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        AdaptiveChrome.fill(colorScheme, dark: 0.05, light: 0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 1)
                    )
                    .onSubmit { attemptUnlock() }

                primaryUnlockButton(
                    title: isUnlocking ? "Unlocking…" : "Unlock Vault",
                    icon: "lock.open.fill",
                    showProgress: isUnlocking
                )
                .disabled(isUnlocking || passphrase.isEmpty)
            }
        } else {
            primaryUnlockButton(
                title: isUnlocking ? "Authenticating…" : "Unlock Vault",
                icon: "touchid",
                showProgress: isUnlocking
            )
            .disabled(isUnlocking)
        }
    }

    private func primaryUnlockButton(title: String, icon: String, showProgress: Bool) -> some View {
        Button {
            attemptUnlock()
        } label: {
            HStack(spacing: 10) {
                if showProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.92) : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.18)
                            : Color.black.opacity(0.2),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .opacity(isUnlocking ? 0.82 : 1)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.red.opacity(colorScheme == .dark ? 0.88 : 0.78))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.red.opacity(colorScheme == .dark ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var securityFootnotes: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                securityBadge("lock.fill", "Keychain")
                securityBadge("desktopcomputer", "This Mac")
                securityBadge("eye.slash", "Never synced")
            }

            if !vault.useCustomVaultPassphrase {
                BiometricAuthNote(compact: true)
            }

            Text("Saved passwords stay encrypted on this device. Searxly never sees them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func securityBadge(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03),
            in: Capsule()
        )
    }

    @ViewBuilder
    private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if glassEnabled {
            shape.fill(toolbarMaterial)
                .searxlyGlass(.regular, in: shape)
        } else {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.14 : 0.1), lineWidth: 1)
    }

    // MARK: - Actions

    private func attemptUnlock() {
        guard !isUnlocking else { return }
        isUnlocking = true
        errorMessage = nil

        Task {
            let success = await vault.unlockVault(
                passphrase: vault.useCustomVaultPassphrase ? passphrase : nil
            )
            isUnlocking = false
            if success {
                passphrase = ""
                onUnlock()
            } else {
                errorMessage = vault.useCustomVaultPassphrase
                    ? "Incorrect passphrase."
                    : "Authentication cancelled or failed."
            }
        }
    }

    private func triggerShake() {
        withAnimation(.linear(duration: 0.06)) {
            shakeOffset = -12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.linear(duration: 0.06)) {
                shakeOffset = 12
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                shakeOffset = 0
            }
        }
    }
}