//
//  ChainMark.swift
//  Searxly
//
//  The wallet's per-network identity badge — a small monochrome mark so each chain is recognizable
//  at a glance (in the switcher, network sheet, and as a corner badge on token icons). White monogram
//  on a dark disc; brand rule is monochrome, so there are deliberately no per-chain colors. Drawn the
//  same spirit as the ETH mark in TokenIconView. Isolated here so the glyph set is easy to
//  upgrade to richer brand artwork later without touching call sites.
//

import SwiftUI

struct ChainMark: View {
    let chainId: Int
    var size: CGFloat = 22

    /// A short, legible monogram per supported chain (Ξ is the canonical Ether mark). Falls back to the
    /// chain's first initial for any id not in the built-in set.
    private var glyph: String {
        switch chainId {
        case WalletChain.ethereum.id: return "Ξ"
        case WalletChain.base.id:     return "B"
        case WalletChain.optimism.id: return "OP"
        case WalletChain.arbitrum.id: return "A"
        case WalletChain.polygon.id:  return "P"
        default: return String((WalletChain.by(id: chainId)?.shortName.first).map(String.init) ?? "?")
        }
    }

    var body: some View {
        Text(glyph)
            .font(.system(size: size * (glyph.count > 1 ? 0.36 : 0.48), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            // Solid dark disc (not translucent) so the badge reads with equal contrast on a glass row
            // and when overlaid on a colorful token logo.
            .background(Circle().fill(Color(red: 0.062, green: 0.062, blue: 0.070)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

/// The "All Networks" companion mark — a 2×2 grid glyph, same disc treatment as a single ChainMark.
struct AllNetworksMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "square.grid.2x2.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(red: 0.062, green: 0.062, blue: 0.070)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}
