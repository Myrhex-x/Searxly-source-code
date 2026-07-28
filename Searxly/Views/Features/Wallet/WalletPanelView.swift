//
//  WalletPanelView.swift
//  Searxly
//
//  Root wallet view — a flat, calm, Phantom-style home. One continuous dark canvas, no dividers,
//  no bands, no borders. The home is: a single header row (account + actions), a centered balance,
//  four round action buttons, and a clean uniform token list. Send / Receive push in with a back
//  button; a small floating segmented control at the bottom switches Home ↔ Activity.
//

import SwiftUI
import Combine

struct WalletPanelView: View {
    var onClose: () -> Void

    @State private var wallet = WalletManager.shared
    @State private var activeTab: WalletTab = .portfolio
    @State private var showSwap = false
    @State private var showBuyNotice = false
    @State private var showAccounts = false
    @State private var showSettings = false
    @State private var showNetworks = false
    /// Coin a flow was opened for (from a coin's detail), so Send/Receive/Swap pre-select it. nil when
    /// opened from the generic home buttons.
    @State private var pendingTokenID: String? = nil

    enum WalletTab { case portfolio, send, receive, activity }

    /// In All-Networks mode the hero/refresh read from the aggregated cross-chain state instead of the
    /// single active chain.
    private var isRefreshing: Bool { wallet.showAllNetworks ? wallet.isAggregating : wallet.isFetchingPrices }
    private var displayedTotal: Double { wallet.showAllNetworks ? wallet.aggregatedTotalUSD : wallet.totalPortfolioUSD }

    var body: some View {
        Group {
            switch wallet.unlockState {
            case .notSetup: WalletSetupView(onClose: onClose)
            case .locked:   WalletLockView(onClose: onClose)
            case .unlocked: unlockedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletTheme.canvas)

    }

    // MARK: - Unlocked content

    private var unlockedContent: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch activeTab {
                case .portfolio:
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            balanceBlock
                            homeActionRow
                            WalletPortfolioView(onTokenAction: handleTokenAction)
                        }
                    }
                case .send:      WalletSendView(initialTokenID: pendingTokenID)
                case .receive:   WalletReceiveView(initialTokenID: pendingTokenID)
                case .activity:  WalletActivityView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom nav lives only on the "destinations"; Send/Receive use the header back arrow.
            if activeTab == .portfolio || activeTab == .activity { bottomNav }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSwap) { WalletSwapView(initialSellID: pendingTokenID) }
        .alert("You're leaving Searxly", isPresented: $showBuyNotice) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { proceedToOnramp() }
        } message: {
            Text("Buying crypto is handled by Onramper, a separate company. They take the payment, run their own identity checks, and set their own prices and fees — Searxly isn't part of the purchase, never sees your card details, and earns nothing from it.\n\nYour receiving address is passed to them so the coins reach this wallet. Their terms and privacy policy apply.")
        }
        .sheet(isPresented: $showAccounts) { WalletAccountsSheet(onClose: { showAccounts = false }) }
        .sheet(isPresented: $showNetworks) { WalletNetworkSheet() }
        .sheet(isPresented: $showSettings) { walletSettingsSheet }
        .onAppear {
            wallet.registerActivity()
            // Pull fresh balances every time the panel opens so funds received while it was closed
            // show up without the user having to do anything. No-ops if the wallet is locked.
            Task {
                if wallet.showAllNetworks { await wallet.refreshAllNetworks() }
                else { await wallet.refreshBalancesAndPrices() }
            }
        }
        .onChange(of: activeTab) { _, _ in wallet.registerActivity() }
    }

    // MARK: - Header (one row: account / back · settings · lock · close)

    private var header: some View {
        HStack(spacing: 10) {
            if activeTab == .send {
                backTitle("Send")
            } else if activeTab == .receive {
                backTitle("Receive")
            } else {
                accountPill
            }

            betaChip

            Spacer()

            if activeTab == .portfolio || activeTab == .activity {
                chainChip
                refreshButton
            }
            headerIconButton("lock", help: "Lock wallet") { wallet.lock() }
            headerIconButton("xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, WalletTheme.pagePadding)
        .padding(.vertical, 14)
    }

    /// Experimental-status marker: the wallet ships in beta. Amber is a genuine warning (brand-legal).
    private var betaChip: some View {
        Text("BETA")
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(WalletTheme.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(WalletTheme.warning.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(WalletTheme.warning.opacity(0.35), lineWidth: 1))
            .help("The wallet is experimental beta software — be cautious and keep only small amounts here while it matures.")
    }

    /// Network switcher chip — shows the active network's mark + name and opens the network sheet.
    /// Same HD address on every chain; switching only changes the RPC, native token, explorer, and
    /// prices. (Brand: monochrome; identity comes from the white ChainMark glyph, never color.)
    private var chainChip: some View {
        Button { showNetworks = true } label: {
            HStack(spacing: 7) {
                if wallet.showAllNetworks {
                    AllNetworksMark(size: 20)
                } else {
                    ChainMark(chainId: wallet.activeChain.id, size: 20)
                }
                Text(wallet.showAllNetworks ? "All Networks" : wallet.activeChain.shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WalletTheme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(WalletTheme.textTertiary)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(WalletTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(WalletTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Switch network")
    }

    /// Flat tappable account selector — avatar, label, short address, chevron. No pill, no border.
    private var accountPill: some View {
        Button { showAccounts = true } label: {
            HStack(spacing: 9) {
                AccountAvatar(address: wallet.activeAccount?.address ?? "", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wallet.activeAccount?.label ?? "Account")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WalletTheme.textPrimary)
                    Text(wallet.activeAccount?.shortAddress ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WalletTheme.textTertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(WalletTheme.textTertiary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 11)
            .padding(.vertical, 5)
            .background(WalletTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(WalletTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Back affordance shown on the Send / Receive screens.
    private func backTitle(_ title: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.14)) { activeTab = .portfolio } } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WalletTheme.textSecondary)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WalletTheme.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Manual balance refresh. Balances also refresh automatically on open, unlock, and after a send,
    /// but a received token can land while the panel sits open — this lets the user pull fresh data
    /// on demand. Spins (and disables) while a fetch is in flight.
    private var refreshButton: some View {
        Button {
            wallet.registerActivity()
            Task {
                if wallet.showAllNetworks { await wallet.refreshAllNetworks() }
                else { await wallet.refreshBalancesAndPrices() }
            }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WalletTheme.textSecondary)
                }
            }
            .frame(width: 30, height: 30)
            .background(WalletTheme.surface, in: Circle())
            .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help("Refresh balances")
    }

    private func headerIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        WalletGlassIconButton(systemName: systemName, help: help, action: action)
    }

    // MARK: - Balance (centered hero, no band / label / chip)

    private var balanceBlock: some View {
        VStack(spacing: 9) {
            // Keep the number on screen during a refresh — show a spinner only on the very first load
            // (when there's genuinely nothing yet), so routine refreshes don't blank the hero.
            if isRefreshing && displayedTotal == 0 {
                ProgressView().scaleEffect(0.7).padding(.vertical, 30)
            } else {
                Text(wallet.formatFiat(displayedTotal))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(WalletTheme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .background(balanceGlow)

                // The 24h change pill + sparkline track the active chain's on-device series, so they're
                // shown only in single-chain mode; All Networks shows the combined total alone.
                if !wallet.showAllNetworks {
                    changePill
                    portfolioMiniChart
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    /// 24h change as a soft direction-colored capsule (green up / red down). Color only ever carries
    /// meaning here — hidden entirely when there's no movement, so the hero stays calm.
    @ViewBuilder
    private var changePill: some View {
        let change = wallet.portfolioChange24h
        if wallet.hasHoldings && change != 0 {
            let tone = change >= 0 ? WalletTheme.positive : WalletTheme.negative
            HStack(spacing: 4) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text(String(format: "%@%.2f%% · today", change >= 0 ? "+" : "−", abs(change)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(tone.opacity(0.13)))
        }
    }

    /// Compact portfolio-value sparkline. Built from on-device snapshots only (no network); hidden
    /// until a real, non-flat-zero series has accumulated.
    @ViewBuilder
    private var portfolioMiniChart: some View {
        let series = wallet.portfolioSeries
        if series.count >= 2, (series.map(\.usd).max() ?? 0) > 0 {
            WalletLineChart(points: series.map { PricePoint(t: $0.t, v: $0.usd) }, compact: true)
                .frame(height: 36)
                .padding(.horizontal, 40)
                .padding(.top, 10)
                .opacity(0.85)
        }
    }

    /// A soft white halo behind the balance number (Phantom-style hero glow).
    private var balanceGlow: some View {
        RadialGradient(
            gradient: Gradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04), .clear]),
            center: .center, startRadius: 2, endRadius: 120
        )
        .frame(width: 300, height: 150)
        .blur(radius: 22)
        .allowsHitTesting(false)
    }

    // MARK: - Quick actions (Receive / Send / Swap / Buy)

    private var homeActionRow: some View {
        // Watch-only accounts have no key — Send and Swap are disabled (Receive/Buy still work).
        let canSign = !wallet.activeAccountIsWatchOnly
        return HStack(spacing: 8) {
            actionButton("Receive", icon: "qrcode") { pendingTokenID = nil; withAnimation(.easeInOut(duration: 0.14)) { activeTab = .receive } }
            actionButton("Send", icon: "paperplane", enabled: canSign) { pendingTokenID = nil; withAnimation(.easeInOut(duration: 0.14)) { activeTab = .send } }
            actionButton("Swap", icon: "arrow.2.squarepath", enabled: canSign) { pendingTokenID = nil; showSwap = true }
            actionButton("Buy", icon: "dollarsign") { openBuy() }
        }
        .padding(.horizontal, WalletTheme.pagePadding)
        .padding(.top, 2)
        .padding(.bottom, 18)
    }

    /// Phantom-style action tile: a rounded-square card with the glyph on top and the label below.
    /// Monochrome — the icon is white, never tinted (Searxly brand).
    private func actionButton(_ label: String, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(WalletTheme.textPrimary)
                    .frame(height: 22)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WalletTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [AdaptiveChrome.dynamic(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.07)), AdaptiveChrome.dynamic(light: Color.black.opacity(0.025), dark: Color.white.opacity(0.035))],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(WalletTheme.hairline, lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// The network follows the asset: switch to the coin's chain, then open the flow pre-targeted to it.
    private func handleTokenAction(_ action: WalletTokenAction, _ token: WalletToken) {
        if let chain = WalletChain.by(id: token.chainId), chain.id != wallet.activeChain.id {
            wallet.switchChain(to: chain)
        }
        pendingTokenID = token.id
        switch action {
        case .send:    withAnimation(.easeInOut(duration: 0.14)) { activeTab = .send }
        case .receive: withAnimation(.easeInOut(duration: 0.14)) { activeTab = .receive }
        case .swap:    showSwap = true
        }
    }

    /// "Buy" hands the user to Onramper — a separate company that sells crypto for card money and
    /// runs its own identity checks. That's a real hand-off to a third-party financial service, with
    /// the user's receiving address prefilled, so it gets an interstitial rather than silently
    /// opening a browser: Searxly sells nothing here, sees no card details, and isn't a party to the
    /// purchase, and the user should know that before they leave.
    private func openBuy() { showBuyNotice = true }

    private func proceedToOnramp() {
        guard let addr = wallet.activeAddress,
              let url = URL(string: WalletConfig.onrampURL(address: addr)) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Bottom tab bar (Home · Swap · Activity · Settings)

    private var bottomNav: some View {
        // Watch-only accounts can't sign, so Swap is dimmed/disabled there (matches the home action row).
        let canSign = !wallet.activeAccountIsWatchOnly
        return HStack(spacing: 0) {
            navTab("Home", icon: "house.fill", selected: activeTab == .portfolio) {
                withAnimation(.easeInOut(duration: 0.14)) { activeTab = .portfolio }
            }
            navTab("Swap", icon: "arrow.2.squarepath", selected: false, enabled: canSign) {
                pendingTokenID = nil; showSwap = true
            }
            navTab("Activity", icon: "clock", selected: activeTab == .activity) {
                withAnimation(.easeInOut(duration: 0.14)) { activeTab = .activity }
            }
            navTab("Settings", icon: "gearshape", selected: false) { showSettings = true }
        }
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(WalletTheme.canvasRaised)
        .overlay(alignment: .top) {
            Rectangle().fill(WalletTheme.hairline).frame(height: 1)
        }
    }

    private func navTab(_ label: String, icon: String, selected: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(label).font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(selected ? WalletTheme.textPrimary : WalletTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Wallet settings (presented from the header gear button)

    private var walletSettingsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wallet Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                Spacer()
                WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { showSettings = false }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            ScrollView { WalletSettingsSection().padding(20) }
        }
        .frame(width: 560, height: 680)
        .background(WalletTheme.canvas)

    }
}

// MARK: - Lock screen

private struct WalletLockView: View {
    var onClose: () -> Void
    @State private var pin = ""
    @State private var showError = false
    @State private var storageUnreadable = false   // seed couldn't be read — NOT a wrong PIN
    @State private var isRecovering = false
    @State private var recoveryCode = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var recoveryError = false
    @State private var wallet = WalletManager.shared
    @State private var now = Date()
    @State private var showDelete = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var lockCountdownText: String {
        let secs = Int(ceil(wallet.pinLockRemaining))
        if secs >= 60 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs)s"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { onClose() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()
            if isRecovering { recoveryView } else { pinEntryView }
            Spacer()
        }
        .onReceive(ticker) { now = $0 }
    }

    private var pinEntryView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(WalletTheme.surfaceStrong)
                        .frame(width: 64, height: 64)
                        .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 1))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(WalletTheme.textSecondary)
                }
                Text("Wallet Locked")
                    .font(.system(size: 19, weight: .semibold))
                Text(WalletFeatures.usesPassphrase ? "Enter your passphrase" : "Enter your 6-digit PIN")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textTertiary)
            }

            if !WalletFeatures.usesPassphrase {
                HStack(spacing: 12) {
                    ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? WalletTheme.ink : WalletTheme.surfaceStrong)
                            .frame(width: 12, height: 12)
                            .animation(.spring(response: 0.18), value: pin.count)
                    }
                }
            }

            if wallet.isPINLocked {
                VStack(spacing: 3) {
                    Text("Too many attempts")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WalletTheme.warning)
                    Text("Try again in \(lockCountdownText)")
                        .font(.system(size: 11))
                        .foregroundStyle(WalletTheme.textTertiary)
                }
            } else if showError {
                Text(wallet.pinAttemptsRemaining <= 2
                     ? "Incorrect · \(wallet.pinAttemptsRemaining) attempt\(wallet.pinAttemptsRemaining == 1 ? "" : "s") left"
                     : "Incorrect")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WalletTheme.negative)
                    .transition(.opacity)
            }

            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { attemptUnlock() }
                .frame(maxWidth: 240)
                .disabled(wallet.isPINLocked)
                .opacity(wallet.isPINLocked ? 0.4 : 1)

            HStack(spacing: 16) {
                if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                    Button {
                        Task { _ = await wallet.unlockWithBiometrics() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: WalletBiometric.symbol)
                                .font(.system(size: 13))
                            Text("Unlock with \(WalletBiometric.label)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(WalletTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }

                Button("Can’t unlock?") {
                    withAnimation { isRecovering = true }
                }
                .font(.system(size: 11))
                .foregroundStyle(WalletTheme.textTertiary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 40)
        .task {
            // Auto-present biometrics when enabled.
            if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                _ = await wallet.unlockWithBiometrics()
            }
        }
    }

    private var recoveryView: some View {
        VStack(spacing: 16) {
            if storageUnreadable {
                // Honest explanation: this isn't a wrong PIN — the seed couldn't be read from this Mac.
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 22)).foregroundStyle(WalletTheme.warning)
                    Text("Your wallet couldn’t be opened")
                        .font(.system(size: 16, weight: .semibold))
                    Text("This Mac’s secure storage couldn’t unlock your wallet — your PIN is likely fine. Reset your PIN with the recovery code below, or start fresh. Your funds are safe on-chain as long as you have your recovery code or 12-word phrase.")
                        .font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)
            } else {
                Text("Recovery Code")
                    .font(.system(size: 17, weight: .semibold))
                Text("Enter the recovery code you saved during setup.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }

            SecureField("Recovery code (32 characters)", text: $recoveryCode)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .background(WalletTheme.surfaceField, in: RoundedRectangle(cornerRadius: WalletTheme.radiusField))
                .frame(maxWidth: 300)

            SecureField("New 6-digit PIN", text: $newPIN)
                .textFieldStyle(.plain)
                .padding(12)
                .background(WalletTheme.surfaceField, in: RoundedRectangle(cornerRadius: WalletTheme.radiusField))
                .frame(maxWidth: 300)

            SecureField("Confirm new PIN", text: $confirmPIN)
                .textFieldStyle(.plain)
                .padding(12)
                .background(WalletTheme.surfaceField, in: RoundedRectangle(cornerRadius: WalletTheme.radiusField))
                .frame(maxWidth: 300)

            if recoveryError {
                Text("Invalid recovery code or PIN mismatch")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.negative)
            }

            HStack(spacing: 12) {
                Button("Back") { withAnimation { isRecovering = false; recoveryError = false; storageUnreadable = false } }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Button("Reset PIN") { attemptRecovery() }
                    .buttonStyle(.borderedProminent)
                    .tint(WalletTheme.ink)
                    .foregroundStyle(WalletTheme.onInk)
                    .controlSize(.regular)
                    .disabled(recoveryCode.count < 16 || newPIN.count != WalletConfig.pinLength || newPIN != confirmPIN)
            }

            Button("Delete Wallet & Start Fresh") {
                showDelete = true
            }
            .font(.system(size: 11))
            .foregroundStyle(WalletTheme.negative.opacity(0.7))
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .sheet(isPresented: $showDelete) {
            DeleteWalletSheet(
                requiresPIN: false,   // user is locked out without a PIN
                onCancel: { showDelete = false },
                onConfirmed: { wallet.deleteWallet(); showDelete = false }
            )
        }
    }

    private func attemptUnlock() {
        guard pin.count == WalletConfig.pinLength else { return }
        Task {
            switch await wallet.unlockDetailedWithSecondFactor(pin: pin) {
            case .unlocked:
                showError = false
            case .storageUnreadable:
                // The PIN may well be correct — secure storage just couldn't be read. Don't blame the PIN;
                // route to recovery (reset with code, or start fresh) with an explanation.
                pin = ""
                showError = false
                withAnimation { storageUnreadable = true; isRecovering = true }
            case .wrongPIN, .locked, .securityKeyFailed:
                // Failed PIN, lockout, or a required security-key tap that didn't complete.
                showError = true
                pin = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showError = false }
            }
        }
    }

    private func attemptRecovery() {
        guard newPIN == confirmPIN else { recoveryError = true; return }
        if !wallet.unlockWithRecoveryCode(recoveryCode, newPIN: newPIN) { recoveryError = true }
    }
}

// MARK: - Portfolio tab (one flat, uniform token list)

private struct WalletPortfolioView: View {
    var onTokenAction: (WalletTokenAction, WalletToken) -> Void = { _, _ in }
    @State private var wallet = WalletManager.shared
    @State private var showAddToken = false
    @State private var detailToken: WalletToken? = nil

    /// Sorted by holding value — the coin you hold the most of (in $) leads. Zero-value rows fall to
    /// the bottom in a stable order (the native gas coin, then A–Z).
    private var orderedTokens: [WalletToken] {
        wallet.visibleTokens.sorted { a, b in
            if a.usdValue != b.usdValue { return a.usdValue > b.usdValue }
            func rank(_ t: WalletToken) -> Int { t.isNative ? 0 : 1 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.symbol < b.symbol
        }
    }

    /// All Networks shows the merged cross-chain holdings; a single chain shows that chain's coins.
    private var portfolioSource: [WalletToken] {
        wallet.showAllNetworks ? wallet.aggregatedTokens : orderedTokens
    }

    var body: some View {
        VStack(spacing: 12) {
            if portfolioSource.isEmpty {
                Text(wallet.showAllNetworks
                     ? "No coins found on any network yet — tap Receive to get your address."
                     : "Your wallet is empty — tap Receive to get your address.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
            } else {
                // One flat, value-sorted card. In All Networks each row shows a small network pill by
                // its name (see tokenRow) so mixed chains stay legible.
                WalletGlassCard(padding: 6) { tokenRows(portfolioSource) }
                    .padding(.horizontal, WalletTheme.pagePadding)
            }

            if !wallet.showAllNetworks, !wallet.hiddenTokenIDs.isEmpty {
                Button { wallet.unhideAllTokens() } label: {
                    Text("Show \(wallet.hiddenTokenIDs.count) hidden token\(wallet.hiddenTokenIDs.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            addCoinButton
                .padding(.horizontal, WalletTheme.pagePadding)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .sheet(isPresented: $showAddToken) { AddTokenSheet() }
        .sheet(item: $detailToken) { token in
            TokenDetailView(token: token, onAction: onTokenAction)
        }
    }

    /// Hairline-split token rows that fill the flat portfolio card.
    private func tokenRows(_ tokens: [WalletToken]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tokens.enumerated()), id: \.element.aggregatedID) { index, token in
                if index > 0 {
                    Rectangle().fill(WalletTheme.divider).frame(height: 1).padding(.leading, 65)
                }
                tokenRow(token)
            }
        }
    }

    private var addCoinButton: some View {
        Button { showAddToken = true } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(WalletTheme.surfaceStrong)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 1))
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WalletTheme.textSecondary)
                }
                Text("Add another coin")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(WalletTheme.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WalletTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .walletGlass(radius: WalletTheme.radiusInner)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A small monochrome network pill shown beside a coin's name in All-Networks mode.
    private func networkPill(_ chainId: Int) -> some View {
        Text(WalletChain.by(id: chainId)?.shortName ?? "")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(WalletTheme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(WalletTheme.surfaceStrong, in: Capsule())
    }

    /// A clean, flat token row. Tap → detail; right-click → copy / hide / remove (kept off the row to
    /// reduce visual noise, Phantom-style).
    @ViewBuilder
    private func tokenRow(_ token: WalletToken) -> some View {
        let funded = token.usdValue > 0
        Button { detailToken = token } label: {
            HStack(spacing: 13) {
                TokenIconView(token: token, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(token.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WalletTheme.textPrimary)
                            .lineLimit(1)
                        // All Networks mixes chains in one list, so a small network pill by the name keeps
                        // e.g. ETH-on-Base distinct from ETH-on-Ethereum. A single chain needs none.
                        if wallet.showAllNetworks {
                            networkPill(token.chainId)
                        }
                    }
                    Text("\(token.formattedBalance) \(token.symbol)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(WalletTheme.textTertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(wallet.formatFiat(token.usdValue))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(funded ? WalletTheme.textPrimary : WalletTheme.textTertiary)
                        .monospacedDigit()
                    if token.balance > 0 && token.change24h != 0 {
                        Text(String(format: "%+.2f%%", token.change24h))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(token.change24h >= 0 ? WalletTheme.positive : WalletTheme.negative)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            // Funded assets read at full strength; empty rows recede so the portfolio's real weight
            // is legible at a glance.
            .opacity(funded ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let addr = token.contractAddress {
                Button("Copy contract address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(addr, forType: .string)
                }
            }
            if !token.isNative {
                Button { WalletManager.shared.hideToken(id: token.id) } label: {
                    Label("Hide token", systemImage: "eye.slash")
                }
            }
            if token.isCustom {
                Divider()
                Button(role: .destructive) {
                    WalletManager.shared.removeCustomToken(id: token.id)
                } label: {
                    Label("Remove token", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - PIN Keypad (shared across setup, lock, send confirm)

struct PINKeypad: View {
    @Binding var pin: String
    let maxLength: Int
    let onComplete: () -> Void
    /// Forces passphrase (true) or PIN (false) mode regardless of the saved wallet setting — used by the
    /// setup / change-secret flows where the user is *choosing* the mode. nil → use the saved setting.
    var passphraseOverride: Bool? = nil

    @State private var reveal = false
    @State private var keyMonitor: Any?
    @Environment(\.isEnabled) private var isEnabled

    private var usesPassphrase: Bool { passphraseOverride ?? WalletFeatures.usesPassphrase }

    private let keys: [[String]] = [
        ["1","2","3"],
        ["4","5","6"],
        ["7","8","9"],
        ["","0","⌫"]
    ]

    var body: some View {
        if usesPassphrase { passphraseField } else { digitGrid }
    }

    private var passphraseField: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if reveal { TextField("Passphrase", text: $pin) }
                    else { SecureField("Passphrase", text: $pin) }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(WalletTheme.textPrimary)
                .autocorrectionDisabled()
                .onSubmit { if !pin.isEmpty { onComplete() } }

                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 13)).foregroundStyle(WalletTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(WalletTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Button { if !pin.isEmpty { onComplete() } } label: {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(pin.isEmpty ? WalletTheme.textTertiary : WalletTheme.onInk)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(pin.isEmpty ? WalletTheme.surfaceStrong : WalletTheme.ink,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(pin.isEmpty)
        }
    }

    private var digitGrid: some View {
        VStack(spacing: 10) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in keyButton(key) }
                }
            }
        }
        // Also accept the physical keyboard (including the numeric keypad). A local key monitor is far
        // more reliable than SwiftUI focus inside sheets. The on-screen keys never reveal the typed
        // number — only the masked dots fill, exactly as if the buttons were tapped.
        .onAppear { startKeyMonitor() }
        .onDisappear { stopKeyMonitor() }
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Maps a physical key to the PIN: a plain digit (main row or numpad) appends, backspace deletes,
    /// Return/Enter submits. Returns nil to consume the key, or the event to let it pass through (so
    /// e.g. Esc still closes the wallet). No-ops when the keypad is disabled (PIN lockout).
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isEnabled,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }

        if let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let ch = chars.first, ch.isNumber {
            if pin.count < maxLength {
                pin.append(ch)
                if pin.count == maxLength {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { onComplete() }
                }
            }
            return nil
        }
        switch event.keyCode {
        case 51:        // delete / backspace
            if !pin.isEmpty { pin.removeLast() }
            return nil
        case 36, 76:    // return / numpad enter
            if pin.count == maxLength { onComplete() }
            return nil
        default:
            return event
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 64, height: 44)
        } else {
            Button {
                if key == "⌫" {
                    if !pin.isEmpty { pin.removeLast() }
                } else if pin.count < maxLength {
                    pin.append(key)
                    if pin.count == maxLength {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { onComplete() }
                    }
                }
            } label: {
                Text(key)
                    .font(.system(size: key == "⌫" ? 16 : 20, weight: .medium))
                    .foregroundStyle(WalletTheme.textPrimary)
                    .frame(width: 64, height: 44)
                    .background(WalletTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
