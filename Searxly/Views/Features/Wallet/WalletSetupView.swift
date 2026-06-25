//
//  WalletSetupView.swift
//  Searxly
//
//  Multi-step flow: Choose → Create/Import/Restore → PIN → Recovery code → Done.
//

import SwiftUI
import AppKit

struct WalletSetupView: View {
    /// Provided when hosted in the wallet overlay (which has no sheet `dismiss`); falls back to the
    /// environment dismiss when used standalone.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("reduceLiquidGlass") private var reduceLiquidGlass = false
    private var glassEnabled: Bool { !reduceLiquidGlass }

    enum SetupStep {
        case choose
        case seedDisplay([String])          // creating: show generated words
        case seedImport                     // importing: user enters words
        case seedConfirmWarning([String])   // after display: "did you write it down?"
        case seedVerify([String])           // quiz a few words so we KNOW it was backed up
        case restorePassword(Data)          // decrypt a chosen encrypted-backup file
        case pinSetup([String])             // set 6-digit PIN
        case recoveryCode(String, [String]) // show one-time recovery code
        case done
    }

    @State private var step: SetupStep = .choose
    @State private var wallet = WalletManager.shared
    @State private var importText = ""
    @State private var importError = ""
    @State private var seedRevealed = false
    @State private var setupError = false
    @State private var restorePass = ""
    @State private var restoreError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.12)

            Group {
                switch step {
                case .choose:             chooseView
                case .seedDisplay(let w): seedDisplayView(words: w)
                case .seedImport:         seedImportView
                case .seedConfirmWarning(let w): warningView(words: w)
                case .seedVerify(let w): SeedVerifyStepView(words: w,
                    onVerified: { step = .pinSetup(w) },
                    onBack: { step = .seedDisplay(w) })
                case .restorePassword(let data): restorePasswordView(fileData: data)
                case .pinSetup(let w):    PINSetupStepView(words: w, wallet: wallet, onDone: { pin, mnemonic in
                    // Only advance if the wallet was actually persisted & verified. On failure nothing
                    // is configured, so we bounce back to start rather than show an unusable wallet.
                    guard let code = wallet.prepareNewWallet(mnemonic: mnemonic, pin: pin) else {
                        setupError = true
                        step = .choose
                        return
                    }
                    step = .recoveryCode(code, mnemonic)
                })
                case .recoveryCode(let code, _): recoveryCodeView(code: code)
                case .done: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Couldn’t create your wallet", isPresented: $setupError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your Mac’s secure storage rejected the wallet, so nothing was saved. Don’t deposit any funds — try again, and if it keeps failing, restart your Mac and retry.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            SearxlyWalletBadge(size: 32, cornerRadius: 8, glassEnabled: glassEnabled)
            Text("Set Up Wallet")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button { if let onClose { onClose() } else { dismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .glassIcon(size: 30, glassEnabled: glassEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Choose

    private var chooseView: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 10) {
                Text("A crypto wallet,\nbuilt into your browser")
                    .font(.system(size: 23, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Hold and send coins on Base. Only you can\naccess it — your keys never leave this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                setupOptionCard(
                    icon: "sparkles",
                    title: "Create a new wallet",
                    subtitle: "We'll give you a 12-word backup phrase to write down."
                ) {
                    let words = wallet.generateMnemonic()
                    step = .seedDisplay(words)
                }

                setupOptionCard(
                    icon: "square.and.arrow.down",
                    title: "I already have a wallet",
                    subtitle: "Restore it with your 12 or 24-word recovery phrase."
                ) {
                    step = .seedImport
                }

                setupOptionCard(
                    icon: "lock.doc",
                    title: "Restore from a backup file",
                    subtitle: "Use an encrypted backup you saved, plus its password."
                ) {
                    pickBackupFile()
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Restore from encrypted backup

    /// Lets the user pick a `.searxlybackup` file, then moves to the password step to decrypt it.
    private func pickBackupFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose your encrypted backup"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        restorePass = ""
        restoreError = false
        step = .restorePassword(data)
    }

    private func restorePasswordView(fileData: Data) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Color.white.opacity(0.08)).frame(width: 72, height: 72)
                Image(systemName: "lock.doc").font(.system(size: 30)).foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text("Unlock your backup").font(.system(size: 18, weight: .semibold))
                Text("Enter the password you set when you saved this backup file.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            }
            SecureField("Backup password", text: $restorePass)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(12).walletGlass(radius: 10, fill: WalletTheme.surfaceField)
                .frame(maxWidth: 280)
                .onSubmit { tryRestore(fileData: fileData) }
            if restoreError {
                Text("Wrong password, or this isn’t a valid Searxly backup file.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.negative)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            }
            VStack(spacing: 12) {
                Button("Restore Wallet") { tryRestore(fileData: fileData) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.large)
                    .disabled(restorePass.isEmpty)
                Button("Back") { restorePass = ""; restoreError = false; step = .choose }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func tryRestore(fileData: Data) {
        guard let words = WalletBackup.restore(fileData: fileData, password: restorePass) else {
            restoreError = true
            return
        }
        // Decrypted a valid mnemonic — continue to PIN setup exactly like a normal import.
        restorePass = ""
        restoreError = false
        step = .pinSetup(words)
    }

    @ViewBuilder
    private func setupOptionCard(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .walletGlass(radius: 14, fill: WalletTheme.surface)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Seed display

    private func seedDisplayView(words: [String]) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Your 12-word backup phrase")
                    .font(.system(size: 18, weight: .semibold))
                Text("These 12 words are the master key to your wallet. Write them down in order, on paper, and keep them somewhere safe. This is the only way to get back in if you lose this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            // Critical warning
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 13)).foregroundStyle(WalletTheme.warning).padding(.top, 1)
                Text("Anyone with these words can take your funds. Never type them into a website and never share them — Searxly will never ask for them.")
                    .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(WalletTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WalletTheme.warning.opacity(0.22), lineWidth: 0.8))
            .padding(.horizontal, 24)

            // 12-word grid (3 columns × 4 rows), blurred until revealed
            ZStack {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 6) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .trailing)
                            Text(word)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .walletGlass(radius: 8, fill: WalletTheme.surfaceField)
                    }
                }
                .padding(.horizontal, 24)
                .blur(radius: seedRevealed ? 0 : 9)

                if !seedRevealed {
                    Button { withAnimation { seedRevealed = true } } label: {
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

            // Optional: copy the phrase to the clipboard to stash in a password manager, instead of
            // (or as well as) writing it down. Shown once revealed, alongside the "I Wrote It Down" path.
            if seedRevealed {
                CopyPhraseButton(words: words)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 10) {
                Button("Back") { seedRevealed = false; step = .choose }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Spacer()

                Button("I Wrote It Down") {
                    seedRevealed = false
                    step = .seedConfirmWarning(words)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.regular)
                .disabled(!seedRevealed)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Import seed

    private var seedImportView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Import Wallet")
                    .font(.system(size: 18, weight: .semibold))
                Text("Enter your 12 or 24-word seed phrase, separated by spaces.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            TextEditor(text: $importText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .walletGlass(radius: 10, fill: WalletTheme.surfaceField)
                .frame(height: 120)
                .padding(.horizontal, 24)
                .onChange(of: importText) { _, _ in importError = "" }

            if !importError.isEmpty {
                Text(importError)
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.negative)
            }

            HStack(spacing: 10) {
                Button("Back") { step = .choose }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                Spacer()

                Button("Next") { validateAndImport() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.regular)
                    .disabled(importText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func validateAndImport() {
        let words = importText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        switch BIP39.validate(words) {
        case .ok:
            step = .pinSetup(words)
        case .badLength:
            importError = "Please enter exactly 12 or 24 words."
        case .unknownWord(let w):
            importError = "“\(w)” isn’t a valid recovery word. Check your spelling."
        case .badChecksum:
            importError = "That phrase has a typo or the words are out of order — its checksum doesn’t match. Re-check each word."
        }
    }

    // MARK: - Warning

    private func warningView(words: [String]) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(WalletTheme.warning.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(WalletTheme.warning)
            }
            VStack(spacing: 8) {
                Text("Have you saved your seed phrase?")
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("If you lose your seed phrase, you will permanently lose access to this wallet. Searxly cannot recover it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                Button("Yes, I Saved It — Continue") { step = .seedVerify(words) }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.large)

                Button("Go Back") { step = .seedDisplay(words) }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Recovery code display

    private func recoveryCodeView(code: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 72, height: 72)
                Image(systemName: "key.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text("Your PIN reset code")
                    .font(.system(size: 18, weight: .semibold))
                Text("If you forget your PIN, this code lets you set a new one. It's different from your 12-word phrase. Save it somewhere safe — you'll only see it once.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Recovery code display
            HStack {
                Text(formattedRecoveryCode(code))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(14)
                    .walletGlass(radius: 10, fill: WalletTheme.surfaceField)

                Button {
                    // Sensitive: concealed copy that auto-clears (won't sync via Universal Clipboard).
                    VaultClipboardManager.shared.copySensitive(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy recovery code (auto-clears in 45s)")
            }
            .padding(.horizontal, 24)

            Button("Done — Open Wallet") {
                wallet.activateUnlock()
                // WalletPanelView will switch to unlocked content once unlockState changes.
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .controlSize(.large)

            Spacer()
        }
    }

    private func formattedRecoveryCode(_ code: String) -> String {
        // Format as XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
        var result = ""
        for (i, char) in code.enumerated() {
            if i > 0 && i % 4 == 0 { result.append("-") }
            result.append(char)
        }
        return result
    }
}

// MARK: - PIN setup step (extracted for compiler tractability)

private struct PINSetupStepView: View {
    let words: [String]
    let wallet: WalletManager
    let onDone: (String, [String]) -> Void

    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var isConfirming = false
    @State private var mismatch = false
    @State private var usePassphrase = false
    @State private var tooShort = false

    private var secretWord: String { usePassphrase ? "passphrase" : "PIN" }

    /// Without a Secure Enclave the seed can only be wrapped under the PIN-derived key (no device
    /// binding), so a 6-digit PIN would be brute-forceable offline. On such hardware we require a
    /// passphrase and hide the PIN option entirely.
    private var seAvailable: Bool { WalletKeychain.isSecureEnclaveAvailable }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 6) {
                Text(isConfirming ? "Confirm \(usePassphrase ? "Passphrase" : "PIN")"
                                  : (usePassphrase ? "Set a Passphrase" : "Set a 6-Digit PIN"))
                    .font(.system(size: 18, weight: .semibold))
                Text(isConfirming
                     ? "Enter the same \(secretWord) again to confirm."
                     : (usePassphrase
                        ? "At least \(WalletConfig.minPassphraseLength) characters — much harder to brute-force than a PIN."
                        : "You'll use this PIN every time you open your wallet."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !seAvailable && !isConfirming {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 12)).foregroundStyle(WalletTheme.warning).padding(.top, 1)
                    Text("This Mac has no Secure Enclave, so a passphrase (not a 6-digit PIN) is required — it's what keeps your seed safe from offline guessing if the encrypted file is ever copied.")
                        .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(WalletTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WalletTheme.warning.opacity(0.22), lineWidth: 0.8))
                .padding(.horizontal, 24)
            }

            if !usePassphrase {
                HStack(spacing: 14) {
                    let displayPin = isConfirming ? confirmPin : pin
                    ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < displayPin.count ? Color.white : WalletTheme.surfaceStrong)
                            .frame(width: 14, height: 14)
                            .animation(.spring(response: 0.2), value: displayPin.count)
                    }
                }
            }

            if mismatch {
                Text("They don't match. Try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.negative)
                    .transition(.opacity)
            } else if tooShort {
                Text("Use at least \(WalletConfig.minPassphraseLength) characters.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.negative)
            }

            PINKeypad(pin: isConfirming ? $confirmPin : $pin, maxLength: WalletConfig.pinLength,
                      onComplete: handleComplete, passphraseOverride: usePassphrase)
                .frame(maxWidth: 240)

            // The PIN ↔ passphrase toggle is only offered when a Secure Enclave is present. Without it,
            // a passphrase is mandatory (see `seAvailable`), so we don't let the user pick a PIN.
            if !isConfirming && seAvailable {
                Button {
                    usePassphrase.toggle()
                    pin = ""; confirmPin = ""; tooShort = false
                } label: {
                    Text(usePassphrase ? "Use a 6-digit PIN instead" : "Use a passphrase instead (stronger)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        // On hardware without a Secure Enclave, force passphrase mode up front so the seed is never
        // protected by a brute-forceable 6-digit PIN alone.
        .onAppear { if !seAvailable { usePassphrase = true } }
    }

    private func handleComplete() {
        // Belt-and-suspenders: never accept a non-passphrase secret when there's no Secure Enclave.
        if !seAvailable { usePassphrase = true }
        if !isConfirming {
            if usePassphrase && pin.count < WalletConfig.minPassphraseLength { tooShort = true; return }
            tooShort = false
            isConfirming = true
        } else {
            if pin == confirmPin {
                WalletFeatures.usesPassphrase = usePassphrase
                onDone(pin, words)
            } else {
                mismatch = true
                confirmPin = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    mismatch = false
                    isConfirming = false
                    pin = ""
                }
            }
        }
    }
}

// MARK: - Seed backup verification
//
// Proves the user actually wrote the phrase down before we let them set a PIN. Quizzes three random
// positions multiple-choice (each: the correct word + three decoys from the BIP-39 list). This guards
// against the single biggest cause of crypto loss: clicking "I saved it" without saving anything.
private struct SeedVerifyStepView: View {
    let words: [String]
    let onVerified: () -> Void
    let onBack: () -> Void

    private struct Challenge: Identifiable {
        let id = UUID()
        let position: Int          // 0-based index into the phrase
        let options: [String]
    }

    @State private var challenges: [Challenge] = []
    @State private var picks: [Int: String] = [:]   // position → chosen word
    @State private var showError = false

    private var allAnswered: Bool { picks.count == challenges.count && !challenges.isEmpty }
    private var allCorrect: Bool { challenges.allSatisfy { picks[$0.position] == words[$0.position] } }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 8) {
                Text("Confirm your backup")
                    .font(.system(size: 18, weight: .semibold))
                Text("Tap the correct word for each position to prove you saved your phrase.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            }

            VStack(spacing: 16) {
                ForEach(challenges) { ch in
                    VStack(spacing: 8) {
                        Text("Word #\(ch.position + 1)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(WalletTheme.textTertiary)
                        HStack(spacing: 8) {
                            ForEach(ch.options, id: \.self) { opt in
                                Button {
                                    picks[ch.position] = opt; showError = false
                                } label: {
                                    Text(opt)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(picks[ch.position] == opt ? .black : .white)
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .background(picks[ch.position] == opt ? Color.white : WalletTheme.surfaceStrong,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)

            if showError {
                Text("That doesn’t match your phrase. Check what you wrote down.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.negative)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            }

            VStack(spacing: 12) {
                Button("Continue") {
                    if allCorrect { onVerified() } else { showError = true }
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.large)
                .disabled(!allAnswered)

                Button("Show my phrase again") { onBack() }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .onAppear { if challenges.isEmpty { buildChallenges() } }
    }

    private func buildChallenges() {
        let positions = Array(words.indices).shuffled().prefix(3).sorted()
        challenges = positions.map { idx in
            var options = Set<String>([words[idx]])
            // Decoys are words NOT in the user's phrase, so a "wrong" option is never ambiguously
            // also one of their real words.
            while options.count < 4 {
                if let decoy = BIP39.wordList.randomElement(), !words.contains(decoy) {
                    options.insert(decoy)
                }
            }
            return Challenge(position: idx, options: Array(options).shuffled())
        }
    }
}
