//
//  WalletApprovalsSheet.swift
//  Searxly
//
//  Lists the token approvals (allowances) this wallet has granted and lets the user revoke any of
//  them. Revoking sends an `approve(spender, 0)` transaction, gated by biometric or the
//  rate-limited PIN. Unlimited approvals are highlighted as the riskiest.
//

import SwiftUI

struct WalletApprovalsSheet: View {
    var onClose: () -> Void

    @State private var wallet = WalletManager.shared
    @State private var state: WalletApprovals.LoadState = .loading
    @State private var pendingRevoke: TokenApproval? = nil
    @State private var pin = ""
    @State private var pinError = false
    @State private var revoking = false
    @State private var revokedIDs: Set<String> = []
    @State private var resultMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            ScrollView { content.padding(20) }
        }
        .frame(width: 400)
        .frame(minHeight: 440, maxHeight: 640)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SearxlyWalletBadge(size: 30, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Token Approvals").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("Who can move your tokens").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            }
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { onClose() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let pending = pendingRevoke {
            revokeConfirm(pending)
        } else {
            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Checking your approvals…").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            case .unsupported:
                infoState(icon: "exclamationmark.triangle",
                          title: "Couldn't check approvals",
                          message: "Scanning your full approval history needs a capable data source. Either set an RPC that supports eth_getLogs (e.g. Alchemy) in Settings → Custom RPC, or add a Basescan API key under Wallet Features. Public RPCs cap log queries, so the default can't do it.")
            case .loaded(let approvals):
                if let resultMessage { banner(resultMessage) }
                let active = approvals.filter { !revokedIDs.contains($0.id) }
                if active.isEmpty {
                    infoState(icon: "checkmark.shield",
                              title: "No active approvals",
                              message: "Nothing else can move your tokens. Approvals appear here after you let a dApp spend a token.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(active) { approval in row(approval) }
                    }
                }
            }
        }
    }

    private func row(_ approval: TokenApproval) -> some View {
        HStack(spacing: 12) {
            TokenIconView(token: approval.token, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(approval.token.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if approval.isUnlimited {
                        Text("UNLIMITED")
                            .font(.system(size: 8, weight: .heavy)).tracking(0.4)
                            .foregroundStyle(WalletTheme.warning)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(WalletTheme.warning.opacity(0.14), in: Capsule())
                    }
                }
                Text("Spender \(abbrev(approval.spender))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(WalletTheme.textTertiary)
                Text("Can spend: \(approval.allowanceDisplay)")
                    .font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
            }
            Spacer()
            Button { pendingRevoke = approval; pin = ""; pinError = false } label: {
                Text("Revoke")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(WalletTheme.negative.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(WalletTheme.negative.opacity(0.4), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .walletGlass(radius: 12)
    }

    // MARK: - Revoke confirm (auth)

    private func revokeConfirm(_ approval: TokenApproval) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                TokenIconView(token: approval.token, size: 40)
                Text("Revoke \(approval.token.symbol) approval")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Stops \(abbrev(approval.spender)) from moving your \(approval.token.symbol). Costs a small gas fee in ETH.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            if revoking {
                ProgressView().padding(.vertical, 14)
                Text("Sending…").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            } else {
                if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                    Button { revokeWithBiometrics(approval) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: WalletBiometric.symbol).font(.system(size: 14))
                            Text("Authorize with \(WalletBiometric.label)").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.black).frame(maxWidth: 240).padding(.vertical, 11)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Text("or enter your PIN").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                } else {
                    Text("Enter your PIN to authorize").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
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
                PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { revokeWithPIN(approval) }
                    .frame(maxWidth: 220)
                    .disabled(wallet.isPINLocked)

                Button("Cancel") { pendingRevoke = nil; pin = "" }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
    }

    // MARK: - Bits

    private func infoState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(WalletTheme.textTertiary)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(WalletTheme.textSecondary)
            Text(message).font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 12)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(WalletTheme.positive)
            Text(text).font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(WalletTheme.positive.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private func abbrev(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    // MARK: - Actions

    private func reload() async {
        guard let owner = wallet.activeAddress else { state = .loaded([]); return }
        state = .loading
        state = await WalletApprovals.fetch(tokens: wallet.tokens, owner: owner, rpc: wallet.activeRPCURL)
    }

    private func revokeWithPIN(_ approval: TokenApproval) {
        guard pin.count == WalletConfig.pinLength else { return }
        guard wallet.attemptPIN(pin) else { pinError = true; pin = ""; return }
        let p = pin; pin = ""; pinError = false
        doRevoke(approval, pin: p)
    }

    private func revokeWithBiometrics(_ approval: TokenApproval) {
        Task {
            guard let p = await wallet.authorizeSigningWithBiometrics(reason: "Revoke token approval") else { return }
            doRevoke(approval, pin: p)
        }
    }

    private func doRevoke(_ approval: TokenApproval, pin: String) {
        guard let contract = approval.token.contractAddress else { return }
        revoking = true
        Task {
            let res = await wallet.revokeApproval(tokenContract: contract, spender: approval.spender, pin: pin)
            revoking = false
            if res.hash != nil {
                revokedIDs.insert(approval.id)
                resultMessage = "Revoke sent for \(approval.token.symbol). It clears once the transaction confirms."
                pendingRevoke = nil
            } else {
                resultMessage = res.error ?? "Revoke failed."
                pendingRevoke = nil
            }
        }
    }
}
