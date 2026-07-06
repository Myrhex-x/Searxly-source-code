//
//  WalletNetworkSheet.swift
//  Searxly
//
//  The network switcher, as a sheet (same pattern as Accounts / Swap). Shows "All Networks" plus
//  every supported chain with its ChainMark, name, per-chain balance, and a checkmark on the active
//  one — so multi-chain is obvious and switching is one tap. Same HD address on every chain; switching
//  only changes the RPC, native token, explorer, and prices.
//

import SwiftUI

struct WalletNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var wallet = WalletManager.shared

    /// Per-chain USD total from the aggregated cross-chain snapshot (populated on appear).
    private func chainTotal(_ id: Int) -> Double {
        wallet.aggregatedTokens.filter { $0.chainId == id }.reduce(0) { $0 + $1.usdValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    WalletGlassCard(padding: 6) {
                        row(mark: AnyView(AllNetworksMark(size: 34)),
                            name: "All Networks",
                            subtitle: "Every chain combined",
                            total: wallet.aggregatedTotalUSD,
                            selected: wallet.showAllNetworks) {
                            wallet.setAllNetworks(true); dismiss()
                        }
                    }

                    WalletGlassCard(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(Array(WalletChain.all.enumerated()), id: \.element.id) { i, chain in
                                if i > 0 {
                                    Rectangle().fill(WalletTheme.divider).frame(height: 1).padding(.leading, 52)
                                }
                                row(mark: AnyView(ChainMark(chainId: chain.id, size: 34)),
                                    name: chain.name,
                                    subtitle: "\(chain.nativeSymbol) · gas on \(chain.shortName)",
                                    total: chainTotal(chain.id),
                                    selected: !wallet.showAllNetworks && chain.id == wallet.activeChain.id) {
                                    wallet.setAllNetworks(false)
                                    wallet.switchChain(to: chain)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 380)
        .frame(minHeight: 440, maxHeight: 600)
        .background(WalletTheme.canvas)

        // Pull cross-chain balances so each network shows its total. Cheap no-op if already current.
        .onAppear { Task { await wallet.refreshAllNetworks() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SearxlyWalletBadge(size: 30, cornerRadius: 8, glassEnabled: false)
            Text("Network").font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func row(mark: AnyView, name: String, subtitle: String, total: Double,
                     selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WalletTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(WalletTheme.textTertiary)
                }
                Spacer(minLength: 8)
                if total > 0 {
                    Text(wallet.formatFiat(total))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(WalletTheme.textSecondary)
                        .monospacedDigit()
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WalletTheme.textPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
