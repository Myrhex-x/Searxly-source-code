//
//  RevealRecoveryPhraseSheet.swift
//  Searxly
//
//  Re-displays the wallet's 12-word recovery phrase so a user can back it up again. Gated by
//  biometrics (when enabled) or the rate-limited PIN, then blur-to-reveal — the words are decrypted
//  from the Keychain only after a successful auth and live only in this sheet's state while it's open.
//  Once authenticated, the user can also copy the phrase to the clipboard (CopyPhraseButton) to stash
//  in a password manager; the clipboard is auto-cleared after a short window.
//

import SwiftUI

struct RevealRecoveryPhraseSheet: View {
    var onClose: () -> Void

    @State private var wallet = WalletManager.shared
    @State private var words: [String]? = nil
    @State private var pin = ""
    @State private var pinError = false
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            ScrollView { content.padding(20) }
        }
        .frame(width: 380)
        .frame(minHeight: 440, maxHeight: 640)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SearxlyWalletBadge(size: 30, cornerRadius: 8)
            Text("Recovery Phrase")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { onClose() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let words {
            revealView(words)
        } else {
            authView
        }
    }

    // MARK: - Auth gate

    private var authView: some View {
        VStack(spacing: 16) {
            warningBox("Your 12-word phrase is the master key to your wallet. Anyone who sees it can take your funds — make sure no one is watching your screen.")

            if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                Button { unlockWithBiometrics() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: WalletBiometric.symbol).font(.system(size: 14))
                        Text("Confirm with \(WalletBiometric.label)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: 240).padding(.vertical, 11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Text("or enter your PIN").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            } else {
                Text("Enter your PIN to continue").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            }

            HStack(spacing: 12) {
                ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                    Circle().fill(i < pin.count ? Color.white : WalletTheme.surfaceStrong).frame(width: 11, height: 11)
                }
            }
            if pinError {
                Text(wallet.isPINLocked ? "Too many attempts. Try again later." : "Incorrect PIN")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.negative)
            }
            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { unlockWithPIN() }
                .frame(maxWidth: 220)
                .disabled(wallet.isPINLocked)
                .opacity(wallet.isPINLocked ? 0.4 : 1)
        }
    }

    // MARK: - Reveal

    private func revealView(_ words: [String]) -> some View {
        VStack(spacing: 16) {
            warningBox("Write these down on paper and store them offline. Never type them into a website — Searxly will never ask for them.")

            ZStack {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 6) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(WalletTheme.textTertiary)
                                .frame(width: 20, alignment: .trailing)
                            Text(word)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .walletGlass(radius: 8)
                    }
                }
                .blur(radius: revealed ? 0 : 9)
                .textSelection(.disabled)

                if !revealed {
                    Button { withAnimation { revealed = true } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.fill").font(.system(size: 18))
                            Text("Tap to reveal").font(.system(size: 12, weight: .semibold))
                            Text("Make sure no one is watching").font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Copy the phrase to the clipboard (paste it into a password manager / safe note). Shared
            // with setup. Auto-clears the clipboard after a short window.
            CopyPhraseButton(words: words)

            Button { onClose() } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bits

    private func warningBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13)).foregroundStyle(WalletTheme.warning).padding(.top, 1)
            Text(text)
                .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(WalletTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WalletTheme.warning.opacity(0.25), lineWidth: 0.8))
    }

    // MARK: - Actions

    private func unlockWithPIN() {
        guard pin.count == WalletConfig.pinLength else { return }
        guard wallet.attemptPIN(pin) else { pinError = true; pin = ""; return }
        if let w = WalletKeychain.loadSeed(pin: pin) {
            pinError = false
            words = w
        } else {
            pinError = true
        }
        pin = ""
    }

    private func unlockWithBiometrics() {
        Task {
            guard let p = await wallet.authorizeSigningWithBiometrics(reason: "Show your recovery phrase") else { return }
            if let w = WalletKeychain.loadSeed(pin: p) { words = w }
        }
    }
}
