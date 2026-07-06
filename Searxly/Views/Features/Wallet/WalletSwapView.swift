//
//  WalletSwapView.swift
//  Searxly
//
//  In-wallet token swaps. "You Pay" / "You Receive" cards with a live auto-quote, a token picker that
//  spans every network you hold (picking a coin on another chain switches the active network), and a
//  same-chain swap via the 0x Swap API — or natively through Uniswap v4 for SEARXLY. Monochrome to
//  match the Searxly brand (green only ever signals live/price, never decoration).
//

import SwiftUI

struct WalletSwapView: View {
    /// Pre-selects the coin to swap from (set when opened from a coin's detail). nil → default.
    var initialSellID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var wallet = WalletManager.shared

    @State private var sellID = "ETH"
    @State private var buyID = "SEARXLY"
    @State private var amountText = ""
    @State private var quote: SwapQuote?
    @State private var loadingQuote = false
    @State private var error = ""
    @State private var pin = ""
    @State private var pinError = false
    @State private var swapping = false
    @State private var resultHash: String?
    @State private var showAuth = false
    /// Live execution narration: stages already passed + the one running now (shown while swapping).
    @State private var doneStages: [String] = []
    @State private var currentStage = ""
    /// "0.5 ETH" → "≈ 1,234 SEARXLY", captured at submit time for the success screen.
    @State private var successSummary: (pay: String, receive: String)? = nil
    /// nil = still confirming; .success/.failed = final on-chain outcome; .pending = gave up polling.
    @State private var confirmStatus: WalletNetwork.ReceiptStatus? = nil
    @State private var picker: PickerTarget?
    @State private var quoteTask: Task<Void, Never>?
    /// Directory coins picked to receive that the wallet doesn't track yet (id → token, active chain
    /// only). Transient: the coin is only added to the wallet if a swap into it actually goes through.
    @State private var extraTokens: [String: WalletToken] = [:]
    /// Whether a swap backend exists (own 0x key or the gateway). Cached once — the key lives in the
    /// Keychain, and reading it from `body` did a synchronous Keychain round-trip on every render.
    @State private var hasSwapBackend = SearxlyGateway.isConfigured

    private enum PickerTarget: Int, Identifiable { case pay, receive; var id: Int { rawValue } }

    private var sellToken: WalletToken? { token(for: sellID) }
    private var buyToken: WalletToken? { token(for: buyID) }

    private func token(for id: String) -> WalletToken? {
        wallet.tokens.first { $0.id == id }
            ?? extraTokens[id].flatMap { $0.chainId == wallet.activeChain.id ? $0 : nil }
    }

    private var amount: Decimal? {
        let raw = amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let d = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), d > 0 else { return nil }
        return d
    }

    private var payUSD: Double {
        guard let a = amount, let p = sellToken?.priceUSD, p > 0 else { return 0 }
        return (a as NSDecimalNumber).doubleValue * p
    }
    private var receiveUSD: Double {
        guard let q = quote, let p = buyToken?.priceUSD, p > 0 else { return 0 }
        return q.buyAmountDouble * p
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                content.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 18)
            }
        }
        .frame(width: 380)
        .frame(minHeight: 500, maxHeight: 700)
        .background(WalletTheme.canvas)

        // Keep the sheet up while transactions are being signed/broadcast so progress isn't lost.
        .interactiveDismissDisabled(swapping)
        .onAppear {
            if let initialSellID { sellID = initialSellID }
            // Ensure a valid, DISTINCT receive coin for the active chain (the initial "SEARXLY"
            // default only exists on Base; off Base it wouldn't resolve, and it collides when the
            // user is selling SEARXLY).
            if buyID.isEmpty || buyToken == nil || sameCoin(sellToken, buyToken) {
                applyDefaultBuy(excluding: sellID)
            }
            WalletTokenDirectory.shared.ensureLoaded(chainId: wallet.activeChain.id)
            if wallet.aggregatedTokens.isEmpty { Task { await wallet.refreshAllNetworks() } }
            hasSwapBackend = !WalletFeatures.zeroExAPIKey.isEmpty || SearxlyGateway.isConfigured
        }
        .onChange(of: amountText) { _, _ in scheduleQuote() }
        .sheet(item: $picker) { target in
            WalletSwapTokenSheet(
                mode: target == .pay ? .pay : .receive,
                excludeID: target == .pay ? buyID : sellID,
                onSelect: { token in
                    if target == .pay { onSelectPay(token) } else { onSelectReceive(token) }
                    picker = nil
                },
                onClose: { picker = nil })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SearxlyWalletBadge(size: 30, cornerRadius: 8, glassEnabled: false)
            Text("Swap").font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close") { dismiss() }
                .disabled(swapping)
                .opacity(swapping ? 0.3 : 1)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let hash = resultHash {
            successView(hash)
        } else if swapping {
            swappingView
        } else if showAuth {
            authView
        } else {
            VStack(spacing: 12) {
                if !swapsReady { swapSetupBanner }
                ZStack {
                    VStack(spacing: 6) { payCard; receiveCard }
                    flipButton
                }
                detailsCard
                if !error.isEmpty {
                    Text(error).font(.system(size: 11)).foregroundStyle(WalletTheme.negative)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                primaryArea
            }
        }
    }

    // MARK: - Pay / Receive cards

    private var payCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You Pay").font(.system(size: 12, weight: .medium)).foregroundStyle(WalletTheme.textTertiary)
            HStack(spacing: 10) {
                TextField("0", text: $amountText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(WalletTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                tokenPill(sellToken) { picker = .pay }
            }
            HStack(spacing: 8) {
                Text(payUSD > 0 ? wallet.formatFiat(payUSD) : " ")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
                Spacer(minLength: 4)
                Text(sellToken?.formattedBalance ?? "0")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(WalletTheme.textTertiary)
                fractionButton("50%", 0.5)
                fractionButton("Max", 1.0)
            }
        }
        .padding(14)
        .walletGlass(radius: 16, fill: WalletTheme.surface)
    }

    private var receiveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You Receive").font(.system(size: 12, weight: .medium)).foregroundStyle(WalletTheme.textTertiary)
            HStack(spacing: 10) {
                Text(quote != nil ? prettyAmount(quote!.buyAmountDouble) : "0")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(quote == nil ? WalletTheme.textTertiary : WalletTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Spacer(minLength: 6)
                tokenPill(buyToken) { picker = .receive }
            }
            HStack(spacing: 8) {
                Text(receiveUSD > 0 ? wallet.formatFiat(receiveUSD) : " ")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
                Spacer()
                if loadingQuote { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
        }
        .padding(14)
        .walletGlass(radius: 16, fill: WalletTheme.surface)
    }

    /// The circular flip button that sits in the gap between the two cards (Phantom-style).
    private var flipButton: some View {
        Button { flip() } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(WalletTheme.textPrimary)
                .frame(width: 34, height: 34)
                .background(WalletTheme.surfaceStrong, in: Circle())
                .overlay(Circle().strokeBorder(WalletTheme.canvas, lineWidth: 4))
        }
        .buttonStyle(.plain)
        .help("Flip pay / receive")
    }

    private func tokenPill(_ token: WalletToken?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let token { TokenIconView(token: token, size: 24) }
                Text(token?.symbol ?? "Select")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(WalletTheme.textSecondary)
            }
            .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
            .background(WalletTheme.surfaceStrong, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fractionButton(_ label: String, _ f: Double) -> some View {
        Button { setFraction(f) } label: {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WalletTheme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(WalletTheme.surfaceStrong, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled((sellToken?.balance ?? 0) <= 0)
        .opacity((sellToken?.balance ?? 0) <= 0 ? 0.4 : 1)
    }

    // MARK: - Details (rate / min received / fee / route)

    @ViewBuilder
    private var detailsCard: some View {
        if let q = quote {
            VStack(spacing: 0) {
                detailRow("Rate", "1 \(q.sellToken.symbol) ≈ \(prettyAmount(q.unitPrice)) \(q.buyToken.symbol)")
                rowDivider
                detailRow("Min received", "\(q.minBuyAmountDisplay) \(q.buyToken.symbol)")
                rowDivider
                detailRow("Searxly fee", q.feeBps == 0
                          ? "Free"
                          : q.feePercentText + (q.feeBps == WalletConfig.holderSwapFeeBps ? " · holder" : ""))
                if q.isV4 {
                    rowDivider
                    detailRow("Route", "Uniswap v4 · native")
                }
                if let spender = q.needsAllowanceTo ?? q.permit2Spender {
                    rowDivider
                    detailRow("Note", "One-time approval tx first")
                    rowDivider
                    detailRow("Approval to", shortAddress(spender))
                }
            }
            .walletGlass(radius: 14, fill: WalletTheme.surfaceField)
        }
    }

    private func detailRow(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            Spacer()
            Text(v).font(.system(size: 12, weight: .medium)).foregroundStyle(WalletTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var rowDivider: some View {
        Rectangle().fill(WalletTheme.divider).frame(height: 1).padding(.horizontal, 14)
    }

    private func shortAddress(_ a: String) -> String {
        a.count > 14 ? "\(a.prefix(8))…\(a.suffix(6))" : a
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryArea: some View {
        if !swapsReady {
            actionButton("Turn on swaps in Settings", enabled: false) {}
        } else if sellToken == nil {
            actionButton("Choose a token to pay with", enabled: false) {}
        } else if buyToken == nil || sellID == buyID {
            actionButton("Choose a token to receive", enabled: false) {}
        } else if amount == nil {
            actionButton("Enter an amount", enabled: false) {}
        } else if quote != nil {
            actionButton("Swap Now", enabled: !swapping) { showAuth = true }
        } else {
            actionButton(loadingQuote ? "Finding best price…" : "Swap Now", enabled: false) {}
        }
    }

    // MARK: - Auth (PIN / biometric)

    /// The pay → receive recap card, shared by the auth and in-progress screens.
    private var swapSummaryCard: some View {
        VStack(spacing: 8) {
            summaryLine(sellToken, amountText, payUSD, prefix: "Pay")
            Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WalletTheme.textTertiary)
            summaryLine(buyToken, quote.map { prettyAmount($0.buyAmountDouble) } ?? "0", receiveUSD, prefix: "Receive")
        }
        .padding(14)
        .walletGlass(radius: 16, fill: WalletTheme.surface)
    }

    private var authView: some View {
        VStack(spacing: 14) {
            swapSummaryCard

            if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                actionButton("Authorize with \(WalletBiometric.label)", enabled: true) {
                    Task {
                        if let p = await wallet.authorizeSigningWithBiometrics(reason: "Authorize swap") { await doSwap(pin: p) }
                    }
                }
                Text("or enter your PIN").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            } else {
                Text("Enter your PIN to authorize").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            }
            HStack(spacing: 12) {
                ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                    Circle().fill(i < pin.count ? WalletTheme.ink : WalletTheme.surfaceStrong).frame(width: 11, height: 11)
                }
            }
            if pinError { Text("Incorrect PIN").font(.system(size: 12)).foregroundStyle(WalletTheme.negative) }
            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) {
                guard wallet.attemptPIN(pin) else { pinError = true; pin = ""; return }
                let p = pin; pin = ""
                Task { await doSwap(pin: p) }
            }
            .frame(maxWidth: 220)
            Button("Back") { showAuth = false; pin = ""; pinError = false }
                .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary).buttonStyle(.plain)
            if !error.isEmpty {
                Text(error).font(.system(size: 11)).foregroundStyle(WalletTheme.negative)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - In-progress (approval + swap legs, narrated)

    private var swappingView: some View {
        VStack(spacing: 16) {
            swapSummaryCard

            WalletStageList(done: doneStages, current: currentStage)

            Text("Approvals confirm on-chain before the swap is sent, so this can take a minute. Keep this window open.")
                .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func stageLabel(_ s: SwapStage) -> String {
        switch s {
        case .checking:           return "Checking balances & allowances"
        case .approving(let sym): return "Approving \(sym) for swapping"
        case .authorizing:        return "Authorizing the swap router"
        case .confirmingApproval: return "Waiting for on-chain confirmation"
        case .submitting:         return "Submitting the swap"
        }
    }

    private func summaryLine(_ token: WalletToken?, _ amountStr: String, _ usd: Double, prefix: String) -> some View {
        HStack(spacing: 10) {
            if let token { TokenIconView(token: token, size: 28) }
            VStack(alignment: .leading, spacing: 1) {
                Text(prefix).font(.system(size: 10, weight: .semibold)).foregroundStyle(WalletTheme.textTertiary)
                Text("\(amountStr) \(token?.symbol ?? "")")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer()
            if usd > 0 {
                Text(wallet.formatFiat(usd)).font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            }
        }
    }

    // MARK: - Setup banner / success

    private var swapsReady: Bool {
        guard WalletFeatures.swaps else { return false }
        if let s = sellToken, let b = buyToken, UniswapV4.supports(sell: s, buy: b) { return true }
        return hasSwapBackend
    }

    private var swapSetupBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.horizontal").font(.system(size: 14)).foregroundStyle(WalletTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Turn on swaps").font(.system(size: 12, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                Text(SearxlyGateway.isConfigured
                     ? "Open Settings → Wallet → Wallet Features and turn on **Swaps**. No API key needed."
                     : "Swaps use the 0x aggregator and need a free API key. Open Settings → Wallet → Wallet Features, turn on **Swaps**, and paste a 0x key.")
                    .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(WalletTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WalletTheme.warning.opacity(0.3), lineWidth: 1))
    }

    private func successView(_ hash: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(WalletTheme.textPrimary).padding(.top, 30)
            Text(confirmStatus == .success ? "Swap complete" : "Swap submitted")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
            if let s = successSummary {
                Text("\(s.pay)  →  \(s.receive)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(WalletTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            WalletTxConfirmationLine(
                status: confirmStatus, chainName: wallet.activeChain.name,
                failureText: "The swap failed on-chain (reverted) — your coins were not swapped, only the network fee was spent.")
            Button { if let u = URL(string: wallet.explorerTxURL(hash)) { NSWorkspace.shared.open(u) } } label: {
                Text("View on \(wallet.activeChain.explorerName)").font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary)
            }.buttonStyle(.plain)
            actionButton("Done", enabled: true) { dismiss() }
        }
        .task(id: hash) { await trackConfirmation(hash) }
    }

    /// Polls the swap receipt (~2 minutes max) so the success screen can flip from "submitted"
    /// to a real on-chain outcome. Gives up quietly — Activity keeps tracking it regardless.
    private func trackConfirmation(_ hash: String) async {
        let rpc = wallet.activeRPCURL
        for _ in 0..<40 {
            let status = await WalletNetwork.transactionReceipt(hash: hash, rpc: rpc)
            if Task.isCancelled { return }
            if status != .pending {
                confirmStatus = status
                if status == .success { wallet.registerActivity() }
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
        }
        confirmStatus = .pending
    }

    private func actionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        WalletPrimaryButton(title: title, enabled: enabled, action: action)
    }

    // MARK: - Selection + chain switching

    /// Picking a coin to pay with. If it lives on another network, switch the active chain to it
    /// (swaps are same-chain), then make sure the receive token is valid AND different on that chain.
    private func onSelectPay(_ token: WalletToken) {
        if token.chainId != wallet.activeChain.id, let chain = WalletChain.by(id: token.chainId) {
            wallet.switchChain(to: chain)
            extraTokens.removeAll()   // directory picks are chain-specific
            buyID = ""                // last chain's receive coin doesn't exist here; re-pick below
        }
        sellID = token.id
        // Re-pick the receive coin whenever it's missing or would collide with the new sell coin.
        if buyID.isEmpty || buyID == sellID || buyToken == nil || sameCoin(buyToken, sellToken) {
            applyDefaultBuy(excluding: sellID)
        }
        resetQuote(); scheduleQuote()
    }

    private func onSelectReceive(_ token: WalletToken) {
        // A directory coin the wallet doesn't track yet — keep it resolvable while quoting/swapping.
        if !wallet.tokens.contains(where: { $0.id == token.id }) {
            extraTokens[token.id] = token
        }
        buyID = token.id
        // Guard the reverse collision too: receiving the coin you're paying with makes no sense.
        if sameCoin(sellToken, token) { applyDefaultSell(excluding: buyID) }
        resetQuote(); scheduleQuote()
    }

    /// Two tokens are "the same coin" if they share an id or (for native/symbol coins) a symbol on the
    /// active chain — so ETH-vs-ETH is caught even when one side came from the directory.
    private func sameCoin(_ a: WalletToken?, _ b: WalletToken?) -> Bool {
        guard let a, let b else { return false }
        return a.id == b.id || a.symbol.uppercased() == b.symbol.uppercased()
    }

    /// Preferred receive coins, in order. SEARXLY only exists on Base; the rest come from the wallet's
    /// own list first, then the verified per-chain directory (so chains where we track only the native
    /// coin still get a real default instead of collapsing to sell == buy).
    private static let defaultBuyPrefs = ["SEARXLY", "USDC", "WETH", "USDT", "DAI"]

    /// Sets `buyID` to a sensible receive coin that is guaranteed DIFFERENT from `sell`. Falls back to
    /// "" (→ the pill shows "Select") rather than ever defaulting to the sell coin itself.
    private func applyDefaultBuy(excluding sell: String) {
        buyID = pickDistinct(excluding: sell, preferNativeLast: true) ?? ""
        // The directory may still be loading on a cold chain — fill the default in once it lands.
        if buyID.isEmpty { fillDefaultBuyWhenDirectoryLoads(excluding: sell) }
    }

    /// Symmetric helper for the rare reverse collision (user set receive = the pay coin).
    private func applyDefaultSell(excluding buy: String) {
        if let id = pickDistinct(excluding: buy, preferNativeLast: false) { sellID = id }
    }

    /// The first preferred coin distinct from `exclude`, drawn from the wallet's active-chain list and
    /// then the verified directory (registering any directory pick so it resolves). nil if none yet.
    private func pickDistinct(excluding exclude: String, preferNativeLast: Bool) -> String? {
        let excludeSym = token(for: exclude)?.symbol.uppercased()
        func distinct(id: String, symbol: String) -> Bool {
            id != exclude && symbol.uppercased() != excludeSym
        }

        // 1. The wallet's own tokens for this chain.
        for pref in Self.defaultBuyPrefs {
            if let t = wallet.tokens.first(where: { $0.symbol.uppercased() == pref && distinct(id: $0.id, symbol: $0.symbol) }) {
                return t.id
            }
        }
        // 2. The verified directory (covers chains where we track only the native coin).
        for pref in Self.defaultBuyPrefs {
            if let d = WalletTokenDirectory.shared.search(pref, chainId: wallet.activeChain.id)
                .first(where: { $0.symbol.caseInsensitiveCompare(pref) == .orderedSame }),
               distinct(id: d.address.lowercased(), symbol: d.symbol) {
                let t = directoryToken(d)
                extraTokens[t.id] = t
                return t.id
            }
        }
        // 3. The native gas coin (last resort — reasonable to receive, e.g. USDC→ETH).
        if preferNativeLast, let native = wallet.tokens.first(where: { $0.isNative && distinct(id: $0.id, symbol: $0.symbol) }) {
            return native.id
        }
        // 4. Any other distinct coin we track.
        return wallet.tokens.first(where: { distinct(id: $0.id, symbol: $0.symbol) })?.id
    }

    /// A directory row as a selectable token (same shape `addCustomToken` would create).
    private func directoryToken(_ d: DirectoryToken) -> WalletToken {
        WalletToken(id: d.address.lowercased(), symbol: d.symbol.uppercased(), name: d.name,
                    contractAddress: d.address.lowercased(), decimals: d.decimals, isCustom: false,
                    chainId: d.chainId)
    }

    /// Cold-chain nicety: the directory loads async, so a fresh chain may have no default receive coin
    /// yet. Load it and retry the pick a few times so the receive side fills itself in.
    private func fillDefaultBuyWhenDirectoryLoads(excluding sell: String) {
        WalletTokenDirectory.shared.ensureLoaded(chainId: wallet.activeChain.id)
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !buyID.isEmpty || sellID != sell { return }   // user picked, or sell changed
                if let id = pickDistinct(excluding: sell, preferNativeLast: true) {
                    buyID = id; scheduleQuote(); return
                }
            }
        }
    }

    private func flip() {
        // Only flip when both sides resolve — otherwise we'd move an empty selection around.
        guard sellToken != nil, buyToken != nil else { return }
        let s = sellID; sellID = buyID; buyID = s
        amountText = ""
        resetQuote()
    }

    private func setFraction(_ f: Double) {
        guard let token = sellToken, token.balance > 0 else { return }
        var v = (token.balance as NSDecimalNumber).doubleValue * f
        // Selling the whole native balance would leave nothing to pay gas, so hold back ~1%.
        if f >= 1.0, token.isNative { v *= 0.99 }
        amountText = trimmedInput(v)
        scheduleQuote()
    }

    // MARK: - Quoting

    private func resetQuote() { quote = nil; error = "" }

    /// Debounced live quote — refreshes as the user types or changes tokens.
    private func scheduleQuote() {
        quoteTask?.cancel()
        quote = nil
        guard amount != nil, sellID != buyID, swapsReady, sellToken != nil, buyToken != nil else {
            loadingQuote = false; return
        }
        loadingQuote = true
        quoteTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            await fetchQuote()
        }
    }

    private func fetchQuote() async {
        guard let sell = sellToken, let buy = buyToken, let amt = amount, let taker = wallet.activeAddress else {
            loadingQuote = false; return
        }
        loadingQuote = true; error = ""
        let result = await WalletSwap.quote(sell: sell, buy: buy, sellAmount: amt, taker: taker,
                                            chainId: wallet.activeChain.id,
                                            feeBps: wallet.isSearxlyHolder ? WalletConfig.holderSwapFeeBps
                                                                           : WalletConfig.swapFeeBps)
        if Task.isCancelled { return }
        loadingQuote = false
        switch result {
        case .success(let q): quote = q; error = ""
        case .failure(let e): quote = nil; error = e.localizedDescription
        }
    }

    private func doSwap(pin: String) async {
        guard let q = quote else { return }
        swapping = true; error = ""
        doneStages = []; currentStage = stageLabel(.checking)
        let result = await wallet.executeSwap(quote: q, pin: pin) { stage in
            let label = stageLabel(stage)
            guard label != currentStage else { return }
            if !currentStage.isEmpty { doneStages.append(currentStage) }
            currentStage = label
        }
        swapping = false
        doneStages = []; currentStage = ""
        if let hash = result.hash {
            successSummary = ("\(amountText) \(q.sellToken.symbol)",
                              "≈ \(prettyAmount(q.buyAmountDouble)) \(q.buyToken.symbol)")
            confirmStatus = nil
            resultHash = hash
            // Swapped into a coin the wallet doesn't track yet (picked from the directory) — add it
            // now so the received balance actually shows up instead of silently missing.
            if let bought = q.buyToken.contractAddress,
               !wallet.tokens.contains(where: { $0.id == q.buyToken.id }) {
                wallet.addCustomToken(contractAddress: bought, symbol: q.buyToken.symbol,
                                      name: q.buyToken.name, decimals: q.buyToken.decimals)
            }
        } else { error = result.error ?? "Swap failed"; pinError = false }
    }

    // MARK: - Number formatting

    /// Grouped, trimmed amount for display (e.g. "13,539.58697", "6,769,793.49").
    private func prettyAmount(_ v: Double) -> String {
        if v == 0 { return "0" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = v >= 1000 ? 2 : (v >= 1 ? 5 : 8)
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Plain (ungrouped) decimal string for the amount field, from a 50% / Max tap.
    private func trimmedInput(_ v: Double) -> String {
        if v <= 0 { return "0" }
        var s = String(format: "%.8f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
