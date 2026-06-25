//
//  WalletActivityView.swift
//  Searxly
//
//  Transaction activity feed. Always shows the local record of outgoing transactions with
//  live pending status; if "Full history" is enabled in settings, also shows incoming txs
//  fetched from Basescan.
//

import SwiftUI

struct WalletActivityView: View {
    @State private var store = WalletActivityStore.shared
    @State private var wallet = WalletManager.shared
    @State private var refreshing = false

    // Speed-up / cancel (replace-by-fee)
    struct ReplaceRequest: Identifiable { let id = UUID(); let entry: WalletActivityEntry; let cancel: Bool }
    @State private var replaceRequest: ReplaceRequest?
    @State private var pin = ""
    @State private var actionError: String?
    @State private var working = false

    // Only the active chain's transactions (per-chain feed).
    private var chainEntries: [WalletActivityEntry] { store.entries(forChain: wallet.activeChain.id) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if chainEntries.isEmpty {
                emptyState
            } else {
                WalletGlassCard(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(chainEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Rectangle().fill(WalletTheme.divider).frame(height: 1).padding(.leading, 64)
                            }
                            row(entry)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task(id: wallet.activeChain.id) {
            if WalletFeatures.fullHistory, let addr = wallet.activeAddress {
                refreshing = true
                await store.refreshFullHistory(address: addr)
                refreshing = false
            }
        }
        .sheet(item: $replaceRequest) { req in replaceSheet(req) }
    }

    // MARK: - Speed-up / cancel confirm

    private func replaceSheet(_ req: ReplaceRequest) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(req.cancel ? "Cancel transaction" : "Speed up transaction")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(req.cancel
                     ? "Replaces the stuck transaction with a 0-value transfer to yourself at the same nonce, at higher gas. If the original already confirmed, this does nothing."
                     : "Re-broadcasts the same transaction at the same nonce with ~25% higher gas so it confirms sooner. You'll pay the higher fee.")
                    .font(.system(size: 12)).foregroundStyle(WalletTheme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(.top, 8).padding(.horizontal, 8)

            if wallet.biometricUnlockEnabled && wallet.biometricAvailable {
                Button { Task { await runReplace(req, pin: nil) } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: WalletBiometric.symbol).font(.system(size: 14))
                        Text("Confirm with \(WalletBiometric.label)").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.black).frame(maxWidth: 240).padding(.vertical, 11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                Text("or enter your PIN").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            } else {
                Text("Enter your PIN to confirm").font(.system(size: 12)).foregroundStyle(WalletTheme.textTertiary)
            }

            HStack(spacing: 12) {
                ForEach(0..<WalletConfig.pinLength, id: \.self) { i in
                    Circle().fill(i < pin.count ? Color.white : WalletTheme.surfaceStrong).frame(width: 11, height: 11)
                }
            }
            if let actionError { Text(actionError).font(.system(size: 12)).foregroundStyle(WalletTheme.negative).multilineTextAlignment(.center) }
            if working { ProgressView().controlSize(.small) }
            PINKeypad(pin: $pin, maxLength: WalletConfig.pinLength) { Task { await runReplace(req, pin: pin) } }
                .frame(maxWidth: 220).disabled(working || wallet.isPINLocked)

            Button("Dismiss") { replaceRequest = nil; pin = "" }.buttonStyle(.bordered).controlSize(.regular)
        }
        .padding(22)
        .frame(width: 340)
        .background(WalletTheme.canvas).preferredColorScheme(.dark)
    }

    private func runReplace(_ req: ReplaceRequest, pin maybePin: String?) async {
        working = true; actionError = nil
        let p: String
        if let entered = maybePin {
            // PIN path: enforce the rate-limited lockout, exactly like every other PIN entry, so this
            // flow can't be used to brute-force the PIN around the cooldown.
            guard entered.count == WalletConfig.pinLength, wallet.attemptPIN(entered) else {
                working = false
                actionError = wallet.isPINLocked ? "Too many attempts. Try again later." : "Incorrect PIN."
                pin = ""
                return
            }
            p = entered
        } else {
            guard let bioPin = await wallet.authorizeSigningWithBiometrics(reason: req.cancel ? "Cancel transaction" : "Speed up transaction") else {
                working = false; actionError = "Authentication failed."; return
            }
            p = bioPin
        }
        let result = req.cancel
            ? await wallet.cancelTransaction(req.entry, pin: p)
            : await wallet.speedUpTransaction(req.entry, pin: p)
        working = false
        if result.hash != nil { replaceRequest = nil; pin = "" }
        else { actionError = result.error ?? "Couldn't replace the transaction."; pin = "" }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(WalletTheme.textTertiary)
            Text("No activity yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(WalletTheme.textSecondary)
            Text(WalletFeatures.fullHistory
                 ? "Your transactions will appear here."
                 : "Outgoing transactions appear here.\nEnable Full History in Settings to see incoming too.")
                .font(.system(size: 11))
                .foregroundStyle(WalletTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private func row(_ entry: WalletActivityEntry) -> some View {
        VStack(spacing: 0) {
            txButton(entry)
            if entry.canReplace { replaceActions(entry) }
        }
    }

    /// Speed-up / cancel controls for a still-pending outgoing transaction.
    private func replaceActions(_ entry: WalletActivityEntry) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button { replaceRequest = ReplaceRequest(entry: entry, cancel: false); pin = ""; actionError = nil } label: {
                Label("Speed up", systemImage: "hare").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(WalletTheme.surfaceStrong, in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(WalletTheme.textSecondary)
            Button { replaceRequest = ReplaceRequest(entry: entry, cancel: true); pin = ""; actionError = nil } label: {
                Label("Cancel", systemImage: "xmark").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(WalletTheme.surfaceStrong, in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(WalletTheme.negative)
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 2)
    }

    private func txButton(_ entry: WalletActivityEntry) -> some View {
        Button {
            if let url = URL(string: WalletManager.shared.explorerTxURL(entry.hash)) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(WalletTheme.surface).frame(width: 38, height: 38)
                    Image(systemName: icon(entry))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WalletTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WalletTheme.textPrimary)
                    Text(abbreviated(entry.counterparty))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(WalletTheme.textTertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(entry.kind == .receive ? "+" : "-")\(entry.amount) \(entry.tokenSymbol)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(entry.kind == .receive ? WalletTheme.positive : WalletTheme.textPrimary)
                    statusBadge(entry.status)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(_ status: WalletActivityEntry.Status) -> some View {
        HStack(spacing: 3) {
            switch status {
            case .pending:
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Pending").font(.system(size: 9)).foregroundStyle(WalletTheme.warning)
            case .confirmed:
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(WalletTheme.textTertiary)
                Text("Confirmed").font(.system(size: 9)).foregroundStyle(WalletTheme.textTertiary)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(WalletTheme.negative)
                Text("Failed").font(.system(size: 9)).foregroundStyle(WalletTheme.negative)
            case .replaced:
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8, weight: .bold)).foregroundStyle(WalletTheme.textTertiary)
                Text("Replaced").font(.system(size: 9)).foregroundStyle(WalletTheme.textTertiary)
            }
        }
    }

    private func icon(_ e: WalletActivityEntry) -> String {
        switch e.kind {
        case .send:     return "arrow.up.right"
        case .receive:  return "arrow.down.left"
        case .swap:     return "arrow.2.squarepath"
        case .approve:  return "checkmark.shield"
        case .contract: return "doc.text"
        }
    }

    private func title(_ e: WalletActivityEntry) -> String {
        switch e.kind {
        case .send:     return "Sent"
        case .receive:  return "Received"
        case .swap:     return "Swapped"
        case .approve:  return "Approved"
        case .contract: return "Contract"
        }
    }

    private func abbreviated(_ s: String) -> String {
        guard s.count > 14 else { return s }
        return "\(s.prefix(8))…\(s.suffix(4))"
    }
}
