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
    /// Opens a URL in the browser (used by the Discover tab). Default no-op for previews.
    var onOpenURL: (String) -> Void = { _ in }

    @State private var wallet = WalletManager.shared
    @State private var activeTab: WalletTab = .portfolio
    @State private var showSwap = false
    @State private var showAccounts = false
    @State private var showSettings = false
    /// Coin a flow was opened for (from a coin's detail), so Send/Receive/Swap pre-select it. nil when
    /// opened from the generic home buttons.
    @State private var pendingTokenID: String? = nil

    enum WalletTab { case portfolio, send, receive, activity, discover }

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
        .preferredColorScheme(.dark)
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
                case .discover:  WalletDiscoverView(onOpen: onOpenURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom nav lives only on the "destinations"; Send/Receive use the header back arrow.
            if activeTab == .portfolio || activeTab == .activity || activeTab == .discover { bottomNav }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSwap) { WalletSwapView(initialSellID: pendingTokenID) }
        .sheet(isPresented: $showAccounts) { WalletAccountsSheet(onClose: { showAccounts = false }) }
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

            Spacer()

            if activeTab == .portfolio || activeTab == .activity {
                chainChip
                refreshButton
            }
            headerIconButton("lock", help: "Lock wallet") { wallet.lock() }
            headerIconButton("xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Monochrome network switcher. Same HD address on every chain — switching only changes the
    /// RPC, native token, explorer, and prices. (Brand: monochrome; no per-chain colors.)
    private var chainChip: some View {
        Menu {
            Button { wallet.setAllNetworks(true) } label: {
                if wallet.showAllNetworks { Label("All Networks", systemImage: "checkmark") }
                else { Text("All Networks") }
            }
            Divider()
            ForEach(WalletChain.all) { chain in
                Button {
                    wallet.setAllNetworks(false)
                    wallet.switchChain(to: chain)
                } label: {
                    if !wallet.showAllNetworks && chain.id == wallet.activeChain.id {
                        Label(chain.name, systemImage: "checkmark")
                    } else {
                        Text(chain.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: wallet.showAllNetworks ? "square.grid.2x2.fill" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .semibold))
                Text(wallet.showAllNetworks ? "All Networks" : wallet.activeChain.shortName)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(WalletTheme.textTertiary)
            }
            .foregroundStyle(WalletTheme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(WalletTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(WalletTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
                    .foregroundStyle(.white)
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
        return HStack(spacing: 0) {
            actionButton("Receive", icon: "arrow.down") { pendingTokenID = nil; withAnimation(.easeInOut(duration: 0.14)) { activeTab = .receive } }
            actionButton("Send", icon: "arrow.up", enabled: canSign) { pendingTokenID = nil; withAnimation(.easeInOut(duration: 0.14)) { activeTab = .send } }
            actionButton("Swap", icon: "arrow.2.squarepath", enabled: canSign) { pendingTokenID = nil; showSwap = true }
            actionButton("Buy", icon: "creditcard") { openBuy() }
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 20)
    }

    private func actionButton(_ label: String, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.11), Color.white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 56, height: 56)
                        .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WalletTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.32)
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

    private func openBuy() {
        guard let addr = wallet.activeAddress,
              let url = URL(string: WalletConfig.onrampURL(address: addr)) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Bottom tab bar (Home · Discover · Activity · Settings)

    private var bottomNav: some View {
        HStack(spacing: 0) {
            navTab("Home", icon: "house.fill", selected: activeTab == .portfolio) {
                withAnimation(.easeInOut(duration: 0.14)) { activeTab = .portfolio }
            }
            navTab("Discover", icon: "square.grid.2x2", selected: activeTab == .discover) {
                withAnimation(.easeInOut(duration: 0.14)) { activeTab = .discover }
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

    private func navTab(_ label: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(label).font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(selected ? WalletTheme.textPrimary : WalletTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Wallet settings (presented from the header gear button)

    private var walletSettingsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wallet Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { showSettings = false }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            ScrollView { WalletSettingsSection().padding(20) }
        }
        .frame(width: 560, height: 680)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
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
                            .fill(i < pin.count ? Color.white : WalletTheme.surfaceStrong)
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
                        .foregroundStyle(.white)
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
                    .tint(.white)
                    .foregroundStyle(.black)
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
        switch wallet.unlockDetailed(pin: pin) {
        case .unlocked:
            showError = false
        case .storageUnreadable:
            // The PIN may well be correct — secure storage just couldn't be read. Don't blame the PIN;
            // route to recovery (reset with code, or start fresh) with an explanation.
            pin = ""
            showError = false
            withAnimation { storageUnreadable = true; isRecovering = true }
        case .wrongPIN, .locked:
            showError = true
            pin = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showError = false }
        }
    }

    private func attemptRecovery() {
        guard newPIN == confirmPIN else { recoveryError = true; return }
        if !wallet.unlockWithRecoveryCode(recoveryCode, newPIN: newPIN) { recoveryError = true }
    }
}

// MARK: - Portfolio tab (one flat, uniform token list — SEARXLY pinned first)

private struct WalletPortfolioView: View {
    var onTokenAction: (WalletTokenAction, WalletToken) -> Void = { _, _ in }
    @State private var wallet = WalletManager.shared
    @State private var showAddToken = false
    @State private var detailToken: WalletToken? = nil

    /// Sorted by holding value — the coin you hold the most of (in $) leads. Zero-value rows fall to
    /// the bottom in a stable order (SEARXLY as the home asset, then the native gas coin, then A–Z).
    private var orderedTokens: [WalletToken] {
        wallet.visibleTokens.sorted { a, b in
            if a.usdValue != b.usdValue { return a.usdValue > b.usdValue }
            func rank(_ t: WalletToken) -> Int { t.symbol == "SEARXLY" ? 0 : (t.isNative ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.symbol < b.symbol
        }
    }

    /// What the list renders: the active chain's tokens, or every chain's funded coins in All Networks.
    private var displayedTokens: [WalletToken] {
        wallet.showAllNetworks ? wallet.aggregatedTokens : orderedTokens
    }
    private var isEmpty: Bool {
        wallet.showAllNetworks ? wallet.aggregatedTokens.isEmpty : !wallet.hasHoldings
    }

    var body: some View {
        VStack(spacing: 12) {
            if isEmpty {
                Text(wallet.showAllNetworks
                     ? "No coins found on any network yet — tap Receive to get your address."
                     : "Your wallet is empty — tap Receive to get your address.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 36)
            }

            // One liquid-glass card holds the whole list; rows are split by inset hairlines (the VPN
            // popup's "rows in a card" rhythm) so the portfolio reads as a single cohesive surface.
            if !displayedTokens.isEmpty {
                WalletGlassCard(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(displayedTokens.enumerated()), id: \.element.aggregatedID) { index, token in
                            if index > 0 {
                                Rectangle()
                                    .fill(WalletTheme.divider)
                                    .frame(height: 1)
                                    .padding(.leading, 65)
                            }
                            tokenRow(token, showChain: wallet.showAllNetworks)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            if !wallet.showAllNetworks, !wallet.hiddenTokenIDs.isEmpty {
                Button { wallet.unhideAllTokens() } label: {
                    Text("Show \(wallet.hiddenTokenIDs.count) hidden token\(wallet.hiddenTokenIDs.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            addCoinButton
                .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .sheet(isPresented: $showAddToken) { AddTokenSheet() }
        .sheet(item: $detailToken) { token in
            TokenDetailView(token: token, onAction: onTokenAction)
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

    /// A clean, flat token row. Tap → detail; right-click → copy / hide / remove (kept off the row to
    /// reduce visual noise, Phantom-style).
    @ViewBuilder
    private func tokenRow(_ token: WalletToken, showChain: Bool = false) -> some View {
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
                        if showChain {
                            Text((WalletChain.by(id: token.chainId) ?? .base).shortName)
                                .font(.system(size: 9, weight: .bold)).tracking(0.3)
                                .foregroundStyle(WalletTheme.textTertiary)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(WalletTheme.surfaceStrong, in: Capsule())
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
            // is legible at a glance (SEARXLY stays a touch brighter as the home asset).
            .opacity(funded ? 1 : (token.symbol == "SEARXLY" ? 0.7 : 0.5))
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
            if token.symbol != "SEARXLY" {
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
                .foregroundStyle(.white)
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
                    .foregroundStyle(pin.isEmpty ? WalletTheme.textTertiary : .black)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(pin.isEmpty ? WalletTheme.surfaceStrong : Color.white,
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
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 44)
                    .background(WalletTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
