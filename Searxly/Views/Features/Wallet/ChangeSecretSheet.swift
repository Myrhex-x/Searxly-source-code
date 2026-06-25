//
//  ChangeSecretSheet.swift
//  Searxly
//
//  Changes the wallet's unlock secret and lets the user switch between a 6-digit PIN and a long
//  alphanumeric passphrase. Re-encrypts the seed (and imported keys) under the new secret via
//  WalletManager.changeSecret. The current-secret step is rate-limited like every other PIN entry.
//

import SwiftUI

struct ChangeSecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var wallet = WalletManager.shared

    private enum Step { case verify, choose, confirm }
    @State private var step: Step = .verify
    @State private var current = ""
    @State private var newSecret = ""
    @State private var confirmSecret = ""
    @State private var newIsPassphrase = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).padding(.top, 24)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)

            if step == .choose {
                // The PIN option is only offered with a Secure Enclave. Without one, a passphrase is
                // mandatory (a 6-digit PIN alone is brute-forceable offline from the encrypted seed).
                if seAvailable {
                    Picker("", selection: $newIsPassphrase) {
                        Text("6-digit PIN").tag(false)
                        Text("Passphrase").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 240).labelsHidden()
                    .onChange(of: newIsPassphrase) { _, _ in newSecret = "" }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12)).foregroundStyle(WalletTheme.warning).padding(.top, 1)
                        Text("This Mac has no Secure Enclave, so a passphrase is required — a 6-digit PIN could be brute-forced offline if the encrypted seed is ever copied.")
                            .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(WalletTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WalletTheme.warning.opacity(0.25), lineWidth: 0.8))
                    .frame(width: 280)
                }
            }

            // PIN-mode progress dots (passphrase shows its own masked field instead).
            if !activeIsPassphrase {
                HStack(spacing: 12) {
                    ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                        Circle().fill(i < activeCount ? Color.white : WalletTheme.surfaceStrong).frame(width: 11, height: 11)
                    }
                }
            }

            if let error { Text(error).font(.system(size: 12)).foregroundStyle(WalletTheme.negative) }

            entry.frame(maxWidth: 260)

            Button("Cancel") { dismiss() }.buttonStyle(.bordered).controlSize(.regular).padding(.bottom, 22)
        }
        .frame(width: 360).frame(minHeight: 420, maxHeight: 560)
        .background(WalletTheme.canvas).preferredColorScheme(.dark)
        // No Secure Enclave → force passphrase mode so the user can't downgrade to a 6-digit PIN.
        .onAppear { if !seAvailable { newIsPassphrase = true } }
    }

    /// See WalletKeychain.isSecureEnclaveAvailable — drives whether a 6-digit PIN is even offered.
    private var seAvailable: Bool { WalletKeychain.isSecureEnclaveAvailable }

    @ViewBuilder
    private var entry: some View {
        switch step {
        case .verify:
            // Current secret is entered in the wallet's EXISTING mode (no override → reads the setting).
            PINKeypad(pin: $current, maxLength: WalletConfig.pinLength, onComplete: verifyCurrent)
        case .choose:
            PINKeypad(pin: $newSecret, maxLength: WalletConfig.pinLength,
                      onComplete: chooseNew, passphraseOverride: newIsPassphrase)
        case .confirm:
            PINKeypad(pin: $confirmSecret, maxLength: WalletConfig.pinLength,
                      onComplete: confirmNew, passphraseOverride: newIsPassphrase)
        }
    }

    // MARK: - Copy

    private var title: String {
        switch step {
        case .verify:  return "Verify current \(WalletFeatures.usesPassphrase ? "passphrase" : "PIN")"
        case .choose:  return "New \(newIsPassphrase ? "passphrase" : "PIN")"
        case .confirm: return "Confirm new \(newIsPassphrase ? "passphrase" : "PIN")"
        }
    }
    private var subtitle: String {
        switch step {
        case .verify:  return "Enter your current secret to continue."
        case .choose:  return newIsPassphrase ? "Use at least \(WalletConfig.minPassphraseLength) characters — much harder to guess than a PIN." : "Choose a 6-digit PIN."
        case .confirm: return "Enter it again to confirm."
        }
    }

    private var activeIsPassphrase: Bool { step == .verify ? WalletFeatures.usesPassphrase : newIsPassphrase }
    private var activeCount: Int {
        switch step {
        case .verify:  return current.count
        case .choose:  return newSecret.count
        case .confirm: return confirmSecret.count
        }
    }

    // MARK: - Steps

    private func verifyCurrent() {
        guard wallet.attemptPIN(current) else {
            error = wallet.isPINLocked ? "Too many tries — wait and retry." : "Incorrect. Try again."
            current = ""
            return
        }
        error = nil; step = .choose
    }

    private func chooseNew() {
        if !seAvailable { newIsPassphrase = true }   // never allow a PIN downgrade without a Secure Enclave
        if newIsPassphrase {
            guard newSecret.count >= WalletConfig.minPassphraseLength else {
                error = "Use at least \(WalletConfig.minPassphraseLength) characters."; return
            }
        } else if newSecret.count != WalletConfig.pinLength {
            error = "PIN must be \(WalletConfig.pinLength) digits."; return
        }
        error = nil; step = .confirm
    }

    private func confirmNew() {
        guard confirmSecret == newSecret else {
            error = "Doesn't match. Try again."; confirmSecret = ""; return
        }
        guard wallet.changeSecret(current: current, new: newSecret, newIsPassphrase: newIsPassphrase) else {
            error = "Couldn't update your secret. Try again."; return
        }
        dismiss()
    }
}
