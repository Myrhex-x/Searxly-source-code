//
//  WalletDiscoverView.swift
//  Searxly
//
//  A curated, monochrome directory of privacy-respecting dApps. Tapping one opens it in a normal
//  browser tab; the wallet's existing protections (origin-bound approval, phishing guard, optional
//  per-dApp rotating address) apply automatically.
//

import SwiftUI

struct WalletDiscoverView: View {
    /// Opens a dApp URL in the browser (and closes the wallet panel).
    var onOpen: (String) -> Void

    @State private var category: DiscoverDApp.Category? = nil

    private var filtered: [DiscoverDApp] {
        guard let category else { return WalletDiscover.dapps }
        return WalletDiscover.dapps.filter { $0.category == category }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Apps that work with your wallet. They open in a tab — Searxly asks before any site connects, and you can give each one its own address in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(WalletTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                categoryBar

                VStack(spacing: 10) {
                    ForEach(filtered) { dapp in tile(dapp) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: category == nil) { category = nil }
                ForEach(DiscoverDApp.Category.allCases) { c in
                    chip(c.rawValue, selected: category == c) { category = (category == c ? nil : c) }
                }
            }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? WalletTheme.canvas : WalletTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.white : WalletTheme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tile(_ dapp: DiscoverDApp) -> some View {
        Button { onOpen(dapp.url) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WalletTheme.surfaceStrong)
                        .frame(width: 40, height: 40)
                    Image(systemName: dapp.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(WalletTheme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(dapp.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                        Text(dapp.category.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(WalletTheme.textTertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(WalletTheme.surface, in: Capsule())
                    }
                    Text(dapp.tagline).font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                        .lineLimit(1)
                    if let note = dapp.privacyNote {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield").font(.system(size: 9))
                            Text(note).font(.system(size: 10)).lineLimit(2)
                        }
                        .foregroundStyle(WalletTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WalletTheme.textTertiary)
            }
            .padding(12)
            .walletGlass(radius: 12)
        }
        .buttonStyle(.plain)
    }
}
