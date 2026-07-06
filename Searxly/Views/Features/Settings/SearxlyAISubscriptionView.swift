//
//  SearxlyAISubscriptionView.swift
//  Searxly
//
//  The Searxly AI subscription panel shown at the top of the Agent settings: current tier, today's
//  usage, $SEARXLY holder status, and the USDC pass purchase flow. Payment mirrors the Managed-VPN flow
//  (USDC on Base from the in-app wallet → the shared treasury) via `SearxlyAIAccess`.
//
//  Two wallet actions, one auth sheet: BUY a pass (pays USDC) or VERIFY the wallet (a free signature so
//  the gateway can confirm $SEARXLY holdings). Both authorize with Face/Touch ID or the wallet PIN.
//

import SwiftUI

struct SearxlyAISubscriptionView: View {
    @State private var access = SearxlyAIAccess.shared
    @State private var wallet = WalletManager.shared

    private enum AuthAction { case buy, verify }
    @State private var pendingAction: AuthAction = .buy

    @State private var showAuth = false
    @State private var pin = ""
    @State private var pinError = false
    @State private var usdcBalance: Decimal? = nil

    private var plan: SearxlyAIPlan { SearxlyAIPlan.monthly }
    private var walletReady: Bool { wallet.unlockState != .notSetup }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard
            holderRow
            verifyRow
            buyButton
            if !walletReady {
                Text("Set up your Searxly wallet first (Settings → Wallet) to pay with USDC or verify holdings.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.warning)
            }
            if let err = access.phase.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showAuth, onDismiss: { pin = ""; pinError = false }) {
            authSheet
        }
        .task {
            access.refreshDailyWindow()
            access.refreshHolderStatus()
            usdcBalance = await wallet.baseUSDCBalance()
        }
        .onChange(of: access.phase) { _, newValue in
            if newValue == .done {
                showAuth = false
                Task { usdcBalance = await wallet.baseUSDCBalance() }
            }
        }
    }

    // MARK: - Status + usage (the top card)

    private var statusCard: some View {
        SettingsInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(access.tier == .free ? SettingsTheme.textTertiary : SettingsTheme.green)
                        .frame(width: 7, height: 7)
                    Text(access.tier.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    if access.hasActivePass, let p = access.pass {
                        Text("· \(p.daysRemaining)d left")
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                    Spacer()
                    Text("\(access.dailyLimit)/day")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(SettingsTheme.fillSubtle, in: Capsule())
                }

                usageBar
            }
        }
    }

    private var usageBar: some View {
        let used = access.promptsUsedToday
        let limit = max(1, access.dailyLimit)
        let frac = min(1.0, Double(used) / Double(limit))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textSecondary)
                Spacer()
                Text("\(used) / \(access.dailyLimit) prompts")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SettingsTheme.fillStrong)
                    Capsule()
                        .fill(used >= access.dailyLimit ? SettingsTheme.warning : SettingsTheme.inkFill)
                        .frame(width: max(2, geo.size.width * frac))
                }
            }
            .frame(height: 6)
            Text("Resets daily (your local midnight).")
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsTheme.textTertiary)
        }
    }

    // MARK: - Holder row

    private var holderRow: some View {
        let required = access.holderTokensRequired
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: access.isHolder ? "checkmark.seal.fill" : "seal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(access.isHolder ? SettingsTheme.green : SettingsTheme.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(access.isHolder ? "Holding $SEARXLY — \(SearxlyAIConfig.holderDailyPrompts)/day unlocked"
                                     : "Hold ~\(formatTokens(required)) $SEARXLY (≈ $\(formatUSD(SearxlyAIConfig.holderTargetUSD))) for \(SearxlyAIConfig.holderDailyPrompts)/day")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(access.isHolder
                     ? "Stays unlocked for 30 days even if the price moves."
                     : "Pay with a pass, or hold the token — whichever you prefer.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Verify wallet (free signature → lets the gateway check holdings)

    @ViewBuilder
    private var verifyRow: some View {
        if walletReady {
            if access.isWalletVerified {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsTheme.green)
                    Text("Wallet verified — the gateway can confirm your tier.")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        startVerify()
                    } label: {
                        Text("Connect wallet — free, no payment")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    Text("Required to use Searxly AI — a one-tap signature so each person has one identity (this is what prevents abuse). No payment, and no funds ever move.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Buy / renew

    private var buyButton: some View {
        Button {
            startBuy()
        } label: {
            Text(access.hasActivePass
                 ? "Renew Pass — \(formatUSDC(plan.priceUSDC)) USDC"
                 : "Get Pass — \(formatUSDC(plan.priceUSDC)) USDC · \(plan.days) days")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(SettingsTheme.inkFill)
        .foregroundStyle(SettingsTheme.onInk)
        .disabled(!walletReady)
    }

    private func startBuy() {
        access.dismissError()
        pendingAction = .buy
        pin = ""; pinError = false
        showAuth = true
    }

    private func startVerify() {
        access.dismissError()
        pendingAction = .verify
        pin = ""; pinError = false
        showAuth = true
    }

    // MARK: - Auth sheet (buy or verify) — mirrors the wallet send confirm flow

    private var authSheet: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(pendingAction == .buy ? "Searxly AI — \(plan.label)" : "Verify wallet")
                    .font(.system(size: 16, weight: .semibold))
                Text(pendingAction == .buy ? "\(formatUSDC(plan.priceUSDC)) USDC on Base"
                                           : "Free signature — no payment")
                    .font(.system(size: 13))
                    .foregroundStyle(WalletTheme.textSecondary)
            }
            .padding(.top, 22)

            if pendingAction == .buy {
                VStack(spacing: 0) {
                    purchaseRow("Plan", "\(SearxlyAIConfig.passDailyPrompts) prompts/day")
                    Divider().opacity(0.08)
                    purchaseRow("Duration", "\(plan.days) days")
                    Divider().opacity(0.08)
                    purchaseRow("Price", "\(formatUSDC(plan.priceUSDC)) USDC")
                    Divider().opacity(0.08)
                    purchaseRow("Network", "Base")
                }
                .background(WalletTheme.surfaceField, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 22)

                if let bal = usdcBalance, bal < plan.priceUSDC {
                    Text("Your wallet has \(formatUSDC(bal)) USDC — top up to cover \(formatUSDC(plan.priceUSDC)) USDC.")
                        .font(.system(size: 11))
                        .foregroundStyle(WalletTheme.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                }
            } else {
                Text("Required to use Searxly AI — it proves you control this wallet so we can prevent abuse (and unlock higher limits if you hold $SEARXLY). It's free: nothing is sent on-chain and no funds move.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if access.phase.isBusy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Sending USDC payment…")
                        .font(.system(size: 12))
                        .foregroundStyle(WalletTheme.textSecondary)
                    Text("Keep Searxly open until this finishes.")
                        .font(.system(size: 11))
                        .foregroundStyle(WalletTheme.textTertiary)
                }
                .padding(.vertical, 8)
            } else {
                authSection
            }

            if let err = access.phase.errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.negative)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
            }

            Button("Cancel") { showAuth = false }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(access.phase.isBusy)
                .padding(.bottom, 22)
        }
        .frame(width: 360)
        .background(WalletTheme.canvas)

    }

    private var authSection: some View {
        VStack(spacing: 10) {
            if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                Button {
                    Task {
                        let reason = pendingAction == .buy ? "Authorize Searxly AI payment" : "Verify wallet for Searxly AI"
                        if let pinForSigning = await wallet.authorizeSigningWithBiometrics(reason: reason) {
                            await perform(pin: pinForSigning)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: WalletBiometric.symbol).font(.system(size: 14))
                        Text("Authorize with \(WalletBiometric.label)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(WalletTheme.onInk)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 11)
                    .background(WalletTheme.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Text(WalletFeatures.usesPassphrase ? "or enter your passphrase" : "or enter your PIN")
                    .font(.system(size: 11))
                    .foregroundStyle(WalletTheme.textTertiary)
            } else {
                Text(WalletFeatures.usesPassphrase ? "Enter your passphrase to continue" : "Enter your PIN to continue")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textTertiary)
            }

            if !WalletFeatures.usesPassphrase {
                HStack(spacing: 12) {
                    ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? WalletTheme.ink : WalletTheme.surfaceStrong)
                            .frame(width: 11, height: 11)
                    }
                }
            }

            if pinError {
                Text("Incorrect PIN")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.negative)
            }

            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { submit() }
                .frame(maxWidth: 220)
        }
    }

    private func submit() {
        guard wallet.attemptPIN(pin) else { pinError = true; pin = ""; return }
        pinError = false
        let entered = pin
        pin = ""
        Task { await perform(pin: entered) }
    }

    /// Runs the pending wallet action with a validated PIN.
    private func perform(pin: String) async {
        switch pendingAction {
        case .buy:
            await access.purchase(plan: plan, pin: pin)
        case .verify:
            _ = access.mintSession(pin: pin)
            showAuth = false
        }
    }

    // MARK: - Bits

    private func purchaseRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(WalletTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(WalletTheme.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func formatUSDC(_ amount: Decimal) -> String {
        let n = NSDecimalNumber(decimal: amount)
        if n == n.rounding(accordingToBehavior: nil) {
            return String(format: "%.0f", n.doubleValue)
        }
        return String(format: "%.2f", n.doubleValue)
    }

    private func formatUSD(_ amount: Decimal) -> String {
        String(format: "%.0f", NSDecimalNumber(decimal: amount).doubleValue)
    }

    private func formatTokens(_ amount: Decimal) -> String {
        let v = NSDecimalNumber(decimal: amount).doubleValue
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
