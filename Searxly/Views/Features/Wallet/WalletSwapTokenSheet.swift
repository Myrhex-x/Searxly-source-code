//
//  WalletSwapTokenSheet.swift
//  Searxly
//
//  Token picker for the swap screen. In `.pay` mode it lists every coin the user holds across ALL
//  supported networks (Base / Ethereum / OP / Arbitrum / Polygon) — picking one on another chain
//  auto-switches the active network. In `.receive` mode it lists the tokens available on the current
//  chain (swaps are same-chain). Searchable by symbol, name, or contract.
//

import SwiftUI

struct WalletSwapTokenSheet: View {
    enum Mode { case pay, receive }

    let mode: Mode
    /// The counter-token to exclude (the buy token in pay mode, the sell token in receive mode).
    let excludeID: String
    var onSelect: (WalletToken) -> Void
    var onClose: () -> Void

    @State private var wallet = WalletManager.shared
    @State private var directory = WalletTokenDirectory.shared
    @State private var search = ""

    private var title: String { mode == .pay ? "You pay" : "You receive" }

    /// Pay: funded holdings across every chain (falls back to the active chain if the cross-chain
    /// fetch hasn't landed yet). Receive: the active chain's known tokens.
    private var source: [WalletToken] {
        switch mode {
        case .pay:     return wallet.aggregatedTokens.isEmpty ? wallet.visibleTokens : wallet.aggregatedTokens
        case .receive: return wallet.tokens
        }
    }

    private var candidates: [WalletToken] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let own = uniqued(source).filter { t in
            // Exclude the counter-token (same coin on the active chain).
            !(t.id == excludeID && t.chainId == wallet.activeChain.id)
        }.filter { t in
            guard !q.isEmpty else { return true }
            return t.symbol.lowercased().contains(q)
                || t.name.lowercased().contains(q)
                || (t.contractAddress?.lowercased().contains(q) ?? false)
        }
        guard mode == .receive else { return own }
        // Receive: the wallet's own list is tiny (native + customs on non-Base chains), so extend it
        // with the verified per-chain directory — majors by default, full search when typing.
        let tracked = Set(source.compactMap { $0.contractAddress?.lowercased() })
        let extras = (q.isEmpty
                      ? defaultReceiveSuggestions(excluding: tracked)
                      : directory.search(q, chainId: wallet.activeChain.id, excluding: tracked))
            .map(walletToken(from:))
            .filter { !($0.id == excludeID && $0.chainId == wallet.activeChain.id) }
        return uniqued(own + extras)
    }

    /// Majors worth receiving on any chain, resolved from the verified directory by exact symbol.
    /// Empty until the chain's list loads (the directory is observable, so rows appear when it lands).
    private func defaultReceiveSuggestions(excluding tracked: Set<String>) -> [DirectoryToken] {
        ["WETH", "USDC", "USDT", "DAI"].compactMap { sym in
            directory.search(sym, chainId: wallet.activeChain.id, excluding: tracked)
                .first { $0.symbol.caseInsensitiveCompare(sym) == .orderedSame }
        }
    }

    /// A directory coin as a selectable token row (same shape `addCustomToken` would create).
    private func walletToken(from d: DirectoryToken) -> WalletToken {
        WalletToken(id: d.address.lowercased(), symbol: d.symbol.uppercased(), name: d.name,
                    contractAddress: d.address.lowercased(), decimals: d.decimals, isCustom: false,
                    chainId: d.chainId)
    }

    /// Drops rows that collide on (chain, id) — duplicate identities render as repeated rows and
    /// break SwiftUI's list diffing.
    private func uniqued(_ list: [WalletToken]) -> [WalletToken] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.aggregatedID).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            if candidates.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        // Keyed by chain+id: the same coin (ETH, USDC…) exists on several chains, so
                        // plain `id` collides across chains and duplicates/garbles the rows.
                        ForEach(candidates, id: \.aggregatedID) { token in
                            row(token)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 372, height: 540)
        .background(WalletTheme.canvas)

        .onAppear {
            // Make sure the cross-chain holdings are populated for the pay picker.
            if mode == .pay, wallet.aggregatedTokens.isEmpty {
                Task { await wallet.refreshAllNetworks() }
            }
            // The receive picker extends the wallet's list with the chain's verified directory.
            if mode == .receive {
                directory.ensureLoaded(chainId: wallet.activeChain.id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
            if mode == .pay, wallet.isAggregating {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            TextField(mode == .pay ? "Search your tokens" : "Search tokens", text: $search)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(WalletTheme.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .walletGlass(radius: WalletTheme.radiusField, fill: WalletTheme.surfaceField)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func row(_ token: WalletToken) -> some View {
        Button { onSelect(token) } label: {
            HStack(spacing: 11) {
                TokenIconView(token: token, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.symbol).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                    HStack(spacing: 5) {
                        Text(token.name).font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                            .lineLimit(1)
                        networkBadge(token.chainId)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if token.balance > 0 {
                        Text(token.formattedBalance)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(WalletTheme.textPrimary)
                        Text(wallet.formatFiat(token.usdValue))
                            .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }

    /// Small network chip so the same coin on different chains is unambiguous. Only shown when it
    /// adds information (pay mode is cross-chain; receive mode is single-chain).
    @ViewBuilder
    private func networkBadge(_ chainId: Int) -> some View {
        if mode == .pay, let chain = WalletChain.by(id: chainId) {
            Text(chain.shortName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(WalletTheme.textSecondary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(WalletTheme.surfaceStrong, in: Capsule())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(WalletTheme.textTertiary)
            Text(search.isEmpty
                 ? (mode == .pay ? "No coins found in your wallet yet." : "No tokens on \(wallet.activeChain.shortName) to receive.")
                 : "No tokens match “\(search)”.")
                .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
