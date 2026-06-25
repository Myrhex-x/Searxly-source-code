//
//  TokenDetailView.swift
//  Searxly
//
//  Per-token detail: balance, USD value, market price, contract, and quick links.
//  A live price chart opens externally only when the "Price charts" feature is enabled.
//

import SwiftUI

/// An action requested from a coin's detail — routed up so the wallet can switch to the coin's chain
/// and open the flow pre-targeted to it (Phantom-style: the network follows the asset).
enum WalletTokenAction { case send, receive, swap }

struct TokenDetailView: View {
    let token: WalletToken
    /// Invoked when the user taps Send / Receive / Swap for this coin. Default no-op for previews.
    var onAction: (WalletTokenAction, WalletToken) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    @State private var chartRange: ChartRange = .day1
    @State private var chartPoints: [PricePoint] = []
    @State private var chartLoading = false
    @State private var scrubbed: PricePoint?

    @State private var wallet = WalletManager.shared
    @State private var showAlertForm = false
    @State private var alertPriceText = ""
    @State private var alertAbove = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) { body_ }
        }
        .frame(width: 380)
        .frame(minHeight: 440, maxHeight: 580)
        .background(WalletTheme.canvas)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TokenIconView(token: token, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(WalletTheme.textPrimary)
                Text("$\(token.symbol)").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
            }
            Spacer()
            WalletGlassIconButton(systemName: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var body_: some View {
        VStack(spacing: 20) {
            // Balance
            VStack(spacing: 4) {
                Text(WalletManager.shared.formatFiat(token.usdValue))
                    .font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(WalletTheme.textPrimary).monospacedDigit()
                Text("\(token.formattedBalance) \(token.symbol)")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(WalletTheme.textTertiary)
            }
            .padding(.top, 16)

            actionRow
                .padding(.horizontal, 16)

            if WalletFeatures.priceCharts { chartSection }

            // Stats — flat rows, no dividers
            VStack(spacing: 0) {
                statRow("Market price", marketPrice)
                if token.priceUSD > 0 && token.balance > 0 {
                    statRow("24h change", String(format: "%+.2f%%", token.change24h),
                            color: token.change24h >= 0 ? WalletTheme.positive : WalletTheme.negative)
                }
                statRow("Network", WalletManager.shared.activeChain.name)
                if let addr = token.contractAddress {
                    HStack {
                        Text("Contract").font(.system(size: 13)).foregroundStyle(WalletTheme.textTertiary)
                        Spacer()
                        Text(abbreviated(addr)).font(.system(size: 12, design: .monospaced)).foregroundStyle(WalletTheme.textPrimary)
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(addr, forType: .string)
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                                .foregroundStyle(copied ? WalletTheme.positive : WalletTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                }
            }
            .walletGlass(radius: WalletTheme.radiusCard)
            .padding(.horizontal, 20)

            // Price alerts (only meaningful when the token has a price feed)
            if token.priceUSD > 0 { priceAlertSection.padding(.horizontal, 20) }

            // Link
            linkButton("View on \(wallet.activeChain.explorerName)", icon: "arrow.up.right.square", url: explorerURL)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Actions (Send / Receive / Swap for this specific coin)

    private var actionRow: some View {
        let canSign = !wallet.activeAccountIsWatchOnly
        return HStack(spacing: 10) {
            actionButton("Send", icon: "arrow.up", enabled: canSign) { onAction(.send, token); dismiss() }
            actionButton("Receive", icon: "arrow.down") { onAction(.receive, token); dismiss() }
            actionButton("Swap", icon: "arrow.2.squarepath", enabled: canSign) { onAction(.swap, token); dismiss() }
        }
    }

    private func actionButton(_ label: String, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.11), Color.white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 48, height: 48)
                        .overlay(Circle().strokeBorder(WalletTheme.hairline, lineWidth: 1))
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(WalletTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Price alerts

    private var priceAlertSection: some View {
        let alerts = wallet.priceAlerts(forTokenID: token.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PRICE ALERTS").font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(WalletTheme.textTertiary)
                Spacer()
                Button {
                    alertPriceText = String(format: "%.6f", token.priceUSD)
                    withAnimation { showAlertForm.toggle() }
                } label: {
                    Image(systemName: showAlertForm ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(WalletTheme.textSecondary)
                        .frame(width: 24, height: 24).background(WalletTheme.surfaceStrong, in: Circle())
                }
                .buttonStyle(.plain)
            }

            ForEach(alerts) { alert in
                HStack(spacing: 8) {
                    Image(systemName: alert.above ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11)).foregroundStyle(WalletTheme.textSecondary)
                    Text("\(alert.above ? "Above" : "Below") \(wallet.formatFiatPrice(alert.targetUSD))")
                        .font(.system(size: 12)).foregroundStyle(WalletTheme.textPrimary)
                    Spacer()
                    Button { wallet.removePriceAlert(id: alert.id) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .walletGlass(radius: 10)
            }

            if showAlertForm {
                VStack(spacing: 10) {
                    Picker("", selection: $alertAbove) {
                        Text("Rises above").tag(true)
                        Text("Falls below").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    HStack(spacing: 8) {
                        Text("$").font(.system(size: 13)).foregroundStyle(WalletTheme.textTertiary)
                        TextField("Target price (USD)", text: $alertPriceText)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        Button("Set") {
                            if let target = Double(alertPriceText), target > 0 {
                                wallet.addPriceAlert(token: token, targetUSD: target, above: alertAbove)
                                withAnimation { showAlertForm = false }
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .walletGlass(radius: 10, fill: WalletTheme.surfaceField)
                }
            }
        }
    }

    // MARK: - Price chart

    private var chartSection: some View {
        VStack(spacing: 8) {
            // Context line: scrubbed value+time while dragging, else the range's change.
            HStack {
                if let scr = scrubbed {
                    Text(WalletManager.shared.formatFiatPrice(scr.v))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                    if let pct = scrubChange {
                        let tone = pct >= 0 ? WalletTheme.positive : WalletTheme.negative
                        HStack(spacing: 2) {
                            Image(systemName: pct >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .bold))
                            Text(String(format: "%+.2f%%", pct)).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(tone)
                    }
                    Spacer()
                    Text(scrubDate(scr.t)).font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                } else if let ch = rangeChange {
                    Text("\(chartRange.label) change").font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                    Spacer()
                    let tone = ch >= 0 ? WalletTheme.positive : WalletTheme.negative
                    HStack(spacing: 3) {
                        Image(systemName: ch >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .bold))
                        Text(String(format: "%+.2f%%", ch)).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(tone)
                } else {
                    Spacer()
                }
            }
            .frame(height: 14)

            Group {
                if chartLoading && chartPoints.isEmpty {
                    ProgressView().scaleEffect(0.7)
                } else if chartPoints.count >= 2 {
                    WalletLineChart(points: chartPoints, onScrub: { scrubbed = $0 })
                } else {
                    Text("Price chart unavailable for this token")
                        .font(.system(size: 11)).foregroundStyle(WalletTheme.textTertiary)
                }
            }
            .frame(height: 170)

            rangePicker
        }
        .padding(.horizontal, 20)
        .task(id: chartRange) { await loadChart() }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { r in
                Button { chartRange = r; scrubbed = nil } label: {
                    Text(r.label)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(chartRange == r ? WalletTheme.textPrimary : WalletTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(chartRange == r ? WalletTheme.surfaceSelected : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(WalletTheme.surfaceField, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: chartRange)
    }

    /// Percent change across the loaded range (first → last close).
    private var rangeChange: Double? {
        guard let first = chartPoints.first?.v, let last = chartPoints.last?.v, first > 0 else { return nil }
        return (last - first) / first * 100
    }

    /// Percent change from the range start to the hovered point (drives the colored hover readout).
    private var scrubChange: Double? {
        guard let scr = scrubbed, let first = chartPoints.first?.v, first > 0 else { return nil }
        return (scr.v - first) / first * 100
    }

    private func loadChart() async {
        chartLoading = true
        chartPoints = await WalletPriceHistoryStore.shared.series(for: token, range: chartRange)
        chartLoading = false
    }

    private func scrubDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = chartRange == .day1 ? "MMM d, HH:mm" : "MMM d, yyyy"
        return f.string(from: d)
    }

    private func statRow(_ label: String, _ value: String, color: Color = WalletTheme.textPrimary) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(WalletTheme.textTertiary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func linkButton(_ title: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(WalletTheme.textTertiary)
            }
            .foregroundStyle(WalletTheme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .walletGlass(radius: WalletTheme.radiusInner, fill: WalletTheme.surfaceStrong)
        }
        .buttonStyle(.plain)
    }

    private var marketPrice: String {
        WalletManager.shared.formatFiatPrice(token.priceUSD)
    }

    private var explorerURL: String {
        if let addr = token.contractAddress { return WalletManager.shared.explorerTokenURL(addr) }
        return WalletManager.shared.activeChain.explorerBaseURL
    }

    private func abbreviated(_ s: String) -> String {
        guard s.count > 14 else { return s }
        return "\(s.prefix(8))…\(s.suffix(6))"
    }
}
