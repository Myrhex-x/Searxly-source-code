//
//  ZeroExKeySheet.swift
//  Searxly
//
//  Explains why in-app swaps need the user's OWN 0x API key, and lets them paste one without leaving
//  the wallet.
//
//  This is deliberate design, not a missing feature: Searxly runs no swap backend. The quote is
//  fetched by this Mac, with this user's key, straight from 0x — so no Searxly server ever sees the
//  address, the pair, or the amount, and Searxly never relays, routes, or executes the trade. The
//  0.65% fee is a parameter written into that quote and settled on-chain by 0x's own contract, which
//  needs no intermediary. Saying that plainly here is the point: the user should understand that the
//  key is what keeps Searxly out of the middle of their trade.
//

import SwiftUI

struct ZeroExKeySheet: View {
    /// Called after a key is saved, so the presenting view can re-check and drop its setup banner.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saved = false
    @FocusState private var focused: Bool

    /// 0x hands out keys from its dashboard; the free tier is enough for personal swapping.
    private static let dashboardURL = URL(string: "https://dashboard.0x.org")!

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    whyCard
                    stepsCard
                    keyField
                    privacyNote
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Divider().opacity(0.1)
            actionRow
        }
        .frame(width: 460, height: 560)
        .background(WalletTheme.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Swaps need your own 0x key")
                    .font(.system(size: 15, weight: .semibold))
                Text("Free, takes about a minute, no card")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close", size: 28) { dismiss() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Why

    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Why we ask", systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WalletTheme.textPrimary)

            Text("Searxly runs no swap server. With your own key, the price quote goes **straight from this Mac to 0x** — no Searxly server sees the address you're swapping from, the pair, or the amount, and we never relay, route, or execute the trade. Your Mac signs it; you send it.")
                .font(.system(size: 11.5))
                .foregroundStyle(WalletTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("We could have kept a key on our own server and hidden this step. We took it out on purpose: staying out of the middle of your trade is the whole point.")
                .font(.system(size: 11.5))
                .foregroundStyle(WalletTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .walletGlass(radius: 14, fill: WalletTheme.surface)
    }

    // MARK: - How

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How to get one", systemImage: "list.number")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WalletTheme.textPrimary)

            step(1, "Open the 0x dashboard and create a free account.")
            step(2, "Create an app — any name will do.")
            step(3, "Copy its API key and paste it below.")

            Button {
                NSWorkspace.shared.open(Self.dashboardURL)
            } label: {
                HStack(spacing: 6) {
                    Text("Open dashboard.0x.org")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(WalletTheme.textPrimary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(WalletTheme.surfaceStrong, in: Capsule())
            .overlay(Capsule().strokeBorder(WalletTheme.hairlineStrong, lineWidth: 1))
            .padding(.top, 2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .walletGlass(radius: 14, fill: WalletTheme.surface)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(WalletTheme.textPrimary)
                .frame(width: 16, height: 16)
                .background(WalletTheme.surfaceStrong, in: Circle())
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(WalletTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Key entry

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your 0x API key")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WalletTheme.textSecondary)
            SecureField("Paste key…", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($focused)
                .onSubmit(save)
            if saved {
                Label("Saved — swaps are on.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(WalletTheme.positive)
            }
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            note("The key is stored in this Mac's Keychain, device-only and excluded from backups. It is never sent to Searxly.")
            note("Swaps carry a 0.65% Searxly fee, collected on-chain by 0x's settlement contract and shown on every quote before you confirm. Network (gas) fees are separate.")
            note("On-chain swaps are irreversible. Searxly never takes custody of your funds and never signs on your behalf.")
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(WalletTheme.textTertiary).frame(width: 3, height: 3).padding(.top, 6)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(WalletTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Not now") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(WalletTheme.textTertiary)
            Spacer()
            Button(action: save) {
                Text("Save key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(trimmedKey.isEmpty ? WalletTheme.textTertiary : WalletTheme.canvas)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(trimmedKey.isEmpty ? WalletTheme.surfaceStrong : WalletTheme.ink,
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(trimmedKey.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// Saves the key to the Keychain and turns the Swaps feature on, so pasting a key is the only
    /// step — the user shouldn't have to find a separate toggle afterwards.
    private func save() {
        let k = trimmedKey
        guard !k.isEmpty else { return }
        WalletFeatures.zeroExAPIKey = k
        WalletFeatures.swaps = true
        saved = true
        onSaved()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
    }
}
