//
//  WalletAccountsSheet.swift
//  Searxly
//
//  Account switcher. All accounts come from the same 12-word phrase (different HD indexes), so a
//  single backup restores them all. Adding one derives a new address and needs the PIN/biometric.
//  Each connected dApp keeps its own account, so using separate accounts keeps sites un-linkable.
//

import SwiftUI

/// A small, monochrome two-tone avatar derived from an address (on-brand: no color).
struct AccountAvatar: View {
    let address: String
    var size: CGFloat = 18

    var body: some View {
        let h = hash(address)
        let outer = Color(white: 0.28 + Double(h % 28) / 100.0)
        let inner = Color(white: 0.60 + Double((h / 7) % 32) / 100.0)
        ZStack {
            Circle().fill(outer)
            Circle().fill(inner)
                .frame(width: size * 0.46, height: size * 0.46)
                .offset(x: size * 0.13, y: -size * 0.10)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 0.6))
    }

    private func hash(_ s: String) -> Int {
        s.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFFFF }
    }
}

struct WalletAccountsSheet: View {
    var onClose: () -> Void

    @State private var wallet = WalletManager.shared
    @State private var addingAccount = false
    @State private var pin = ""
    @State private var pinError = false
    @State private var renaming: WalletAccount? = nil
    @State private var renameText = ""

    // Import private key / watch-only / hardware sub-flows
    @State private var importing = false
    @State private var watching = false
    @State private var hardware = false
    @State private var keyText = ""
    @State private var labelText = ""
    @State private var watchAddress = ""
    @State private var importError: String? = nil
    @State private var watchError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            ScrollView { content.padding(20) }
        }
        .frame(width: 380)
        .frame(minHeight: 420, maxHeight: 600)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
        .alert("Rename account", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let r = renaming { wallet.renameAccount(index: r.index, label: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var headerTitle: String {
        if addingAccount { return "Add Account" }
        if importing { return "Import Key" }
        if watching { return "Watch Address" }
        if hardware { return "Hardware Wallet" }
        return "Accounts"
    }

    private var header: some View {
        HStack(spacing: 10) {
            SearxlyWalletBadge(size: 30, cornerRadius: 8)
            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { onClose() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if addingAccount {
            addAccountView
        } else if importing {
            importKeyView
        } else if watching {
            watchAddressView
        } else if hardware {
            hardwareView
        } else {
            VStack(spacing: 10) {
                ForEach(wallet.accounts) { account in row(account) }

                // Per-dApp rotating addresses currently assigned to a connected site. Shown so the
                // user can switch to one and spend funds a dApp received there.
                if !wallet.inUseRotationAccounts.isEmpty {
                    HStack {
                        Text("SITE ADDRESSES")
                            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(WalletTheme.textTertiary)
                        Spacer()
                    }
                    .padding(.top, 6)
                    ForEach(wallet.inUseRotationAccounts) { account in row(account, isSite: true) }
                }

                VStack(spacing: 4) {
                    addActionRow("plus", "Add account", "New address from your phrase") {
                        addingAccount = true; pin = ""; pinError = false
                    }
                    addActionRow("key", "Import private key", "Use an external key (stored encrypted)") {
                        importing = true; keyText = ""; labelText = ""; importError = nil; pin = ""; pinError = false
                    }
                    addActionRow("eye", "Watch an address", "Track any address — view only, no signing") {
                        watching = true; watchAddress = ""; labelText = ""; watchError = nil
                    }
                    addActionRow("externaldrive", "Connect hardware wallet", "Sign with a Ledger — keys never touch this Mac") {
                        hardware = true
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func row(_ account: WalletAccount, isSite: Bool = false) -> some View {
        let isActive = account.index == wallet.activeAccountIndex
        return Button {
            wallet.switchAccount(to: account.index)
            onClose()
        } label: {
            HStack(spacing: 12) {
                AccountAvatar(address: account.address, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if isSite {
                            Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
                        }
                        Text(account.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        if account.kind == .imported { kindBadge("IMPORTED") }
                        if account.kind == .watchOnly { kindBadge("WATCH-ONLY") }
                        if account.kind == .hardware { kindBadge("LEDGER") }
                    }
                    Text(account.shortAddress).font(.system(size: 11, design: .monospaced)).foregroundStyle(WalletTheme.textTertiary)
                }
                Spacer()
                if !isSite {
                    Button {
                        renameText = account.label; renaming = account
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                if isActive {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white)
                }
            }
            .padding(12)
            .walletGlass(radius: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Color.white.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renameText = account.label; renaming = account } label: {
                Label("Rename", systemImage: "pencil")
            }
            if wallet.canRemoveAccount(index: account.index) {
                Button(role: .destructive) { wallet.removeAccount(index: account.index) } label: {
                    Label("Remove from list", systemImage: "minus.circle")
                }
            }
        }
    }

    // MARK: - Add account (auth)

    private var addAccountView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Add a new account").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Creates another address from your existing recovery phrase — no new backup needed. Confirm it's you.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(.top, 6)

            if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                Button { addWithBiometrics() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: WalletBiometric.symbol).font(.system(size: 14))
                        Text("Confirm with \(WalletBiometric.label)").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.black).frame(maxWidth: 240).padding(.vertical, 11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Text("or enter your PIN").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            } else {
                Text("Enter your PIN").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
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
            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { tryAddWithPIN() }
                .frame(maxWidth: 220)
                .disabled(wallet.isPINLocked)

            Button("Cancel") { addingAccount = false; pin = "" }
                .buttonStyle(.bordered).controlSize(.regular)
        }
    }

    private func kindBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold)).tracking(0.4)
            .foregroundStyle(WalletTheme.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(WalletTheme.surfaceStrong, in: Capsule())
    }

    private func addActionRow(_ icon: String, _ title: String, _ subtitle: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(WalletTheme.surfaceStrong).frame(width: 34, height: 34)
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(WalletTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(WalletTheme.textPrimary)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import private key

    private var importKeyView: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Import a private key").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Paste a 64-character private key. It's stored encrypted with your PIN, like your phrase. This account isn't covered by your recovery phrase — keep the key safe.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(.top, 6)

            SecureField("Private key (0x…)", text: $keyText)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .padding(10).walletGlass(radius: WalletTheme.radiusField, fill: WalletTheme.surfaceField)
            TextField("Label (optional)", text: $labelText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(10).walletGlass(radius: WalletTheme.radiusField, fill: WalletTheme.surfaceField)

            Text("Enter your PIN to confirm").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            HStack(spacing: 12) {
                ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                    Circle().fill(i < pin.count ? Color.white : WalletTheme.surfaceStrong).frame(width: 11, height: 11)
                }
            }
            if let importError {
                Text(importError).font(.system(size: 12)).foregroundStyle(WalletTheme.negative).multilineTextAlignment(.center)
            }
            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { tryImport() }
                .frame(maxWidth: 220).disabled(wallet.isPINLocked)

            Button("Cancel") { importing = false; pin = "" }.buttonStyle(.bordered).controlSize(.regular)
        }
    }

    private func tryImport() {
        guard pin.count == WalletConfig.pinLength else { return }
        switch wallet.importPrivateKey(keyText, label: labelText, pin: pin) {
        case .ok:        importing = false; pin = ""; keyText = ""; onClose()
        case .badKey:    importError = "That's not a valid private key (need 64 hex characters)."; pin = ""
        case .duplicate: importError = "You already have that address in your wallet."; pin = ""
        case .authFailed: importError = wallet.isPINLocked ? "Too many attempts. Try again later." : "Incorrect PIN."; pin = ""
        }
    }

    // MARK: - Watch-only address

    private var watchAddressView: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Watch an address").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Track any wallet's balance and activity. You can view it but never sign or send — there's no key.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(.top, 6)

            TextField("Address (0x…)", text: $watchAddress)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .padding(10).walletGlass(radius: WalletTheme.radiusField, fill: WalletTheme.surfaceField)
            TextField("Label (optional)", text: $labelText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(10).walletGlass(radius: WalletTheme.radiusField, fill: WalletTheme.surfaceField)

            if let watchError {
                Text(watchError).font(.system(size: 12)).foregroundStyle(WalletTheme.negative).multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Cancel") { watching = false }.buttonStyle(.bordered).controlSize(.regular)
                Button("Add") {
                    if wallet.addWatchOnly(address: watchAddress, label: labelText) { watching = false; onClose() }
                    else { watchError = "Enter a valid 0x address you don't already have." }
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Hardware wallet (Ledger)

    private var hardwareView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(WalletTheme.surfaceStrong).frame(width: 64, height: 64)
                Image(systemName: "externaldrive").font(.system(size: 26)).foregroundStyle(WalletTheme.textSecondary)
            }
            .padding(.top, 10)
            VStack(spacing: 8) {
                Text("Connect a Ledger").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Searxly speaks the Ledger Ethereum protocol — address derivation, transaction and message signing, and the USB-HID framing are all built in and verified. Sign on the device, where your keys never touch this Mac.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).multilineTextAlignment(.center)
            }
            // Honest status: the on-device USB transport (and its USB entitlement) is the final step.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 14)).foregroundStyle(WalletTheme.warning)
                Text("USB device connection ships in a hardware-enabled build. Everything up to the wire is ready.")
                    .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(WalletTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WalletTheme.warning.opacity(0.3), lineWidth: 1))

            Button("Back") { hardware = false }.buttonStyle(.bordered).controlSize(.regular)
        }
        .padding(.horizontal, 4)
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func tryAddWithPIN() {
        guard pin.count == WalletConfig.pinLength else { return }
        if wallet.addAccount(pin: pin) {
            addingAccount = false; pin = ""; pinError = false
        } else {
            pinError = true; pin = ""
        }
    }

    private func addWithBiometrics() {
        Task {
            guard let p = await wallet.authorizeSigningWithBiometrics(reason: "Add a new account") else { return }
            if wallet.addAccount(pin: p) { addingAccount = false; pin = "" }
        }
    }
}
