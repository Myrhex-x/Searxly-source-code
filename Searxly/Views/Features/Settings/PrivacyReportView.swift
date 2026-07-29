//
//  PrivacyReportView.swift
//  Searxly
//
//  The standalone Privacy Report pane (Settings → Privacy Report): a live posture score, actionable
//  "raise your score" shortcuts, the checklist of protections behind the score, and a summary of this
//  session's own outbound traffic (from the egress ledger). See PrivacyReport for the data model.
//

import SwiftUI

struct PrivacyReportView: View {
    /// Jump to another settings pane (wired by SettingsView) so "raise your score" rows are actionable.
    var onNavigate: ((SettingsCategory) -> Void)? = nil

    /// Snapshot of the posture, recomputed on appear and on "Re-check".
    @State private var report = PrivacyReport.current()
    @State private var checking = false

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Privacy Report",
                subtitle: Edition.isMaximum
                    ? "Scored from protections verified on this Mac — never from claims. Cross-check the live posture with the Self-Test in Privacy & Data."
                    : "How protected you are on this Mac — scored from the protections Searxly can actually verify."
            )

            scoreHero(report)

            let suggestions = improvementSuggestions(report)
            if !suggestions.isEmpty {
                improveSection(suggestions)
            }

            protectionsSection(report)
            sessionSection(report)
        }
        .onAppear { report = PrivacyReport.current() }
    }

    // MARK: - Score hero

    private func scoreHero(_ report: PrivacyReport) -> some View {
        SettingsSection(title: "") {
            HStack(spacing: 18) {
                scoreRing(report)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("Grade \(report.grade)")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        Circle().fill(scoreColor(report.score)).frame(width: 8, height: 8)
                    }
                    Text(report.verdict)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(report.activeCount) of \(report.protections.count) protections active")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.textTertiary)
                }
                Spacer(minLength: 8)
                recheckButton
            }
        }
    }

    private var recheckButton: some View {
        Button {
            checking = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                report = PrivacyReport.current()
                checking = false
            }
        } label: {
            HStack(spacing: 6) {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                Text(checking ? "Checking…" : "Re-check").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(SettingsTheme.inkFill, in: Capsule())
            .foregroundStyle(SettingsTheme.onInk)
        }
        .buttonStyle(.plain)
        .disabled(checking)
    }

    private func scoreRing(_ report: PrivacyReport) -> some View {
        ZStack {
            Circle().stroke(SettingsTheme.fillStrong, lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(report.score) / 100)
                .stroke(scoreColor(report.score), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(report.score)")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text("/ 100")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.textTertiary)
            }
        }
        .frame(width: 78, height: 78)
        .animation(.easeOut(duration: 0.4), value: report.score)
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 70...:   return SettingsTheme.green
        case 50..<70: return SettingsTheme.warning
        default:      return SettingsTheme.danger
        }
    }

    // MARK: - Raise your score (actionable shortcuts to enable inactive protections)

    private func improvementSuggestions(_ report: PrivacyReport) -> [PrivacyReport.Protection] {
        let inactive = report.protections.filter { !$0.active }
        // Protections you can turn on individually (VPN, encryption, ad-block, history).
        var result = inactive.filter { $0.id != "fingerprint" && targetCategory(for: $0.id) != nil }
        // Fingerprint scrambling is the one Maximum-gated protection, so it's offered ONLY as the final
        // step — once every other protection is already on (score 90 → 100). That keeps Maximum out of
        // the way until it's genuinely the last thing left to turn on.
        if inactive.allSatisfy({ $0.id == "fingerprint" }),
           let fingerprint = inactive.first(where: { $0.id == "fingerprint" }),
           targetCategory(for: "fingerprint") != nil {
            result.append(fingerprint)
        }
        return result
    }

    /// Which settings pane enables a given protection.
    private func targetCategory(for id: String) -> SettingsCategory? {
        switch id {
        case "ip":                               return Edition.isMaximum ? nil : .vpn
        case "encryption", "adblock", "history": return .privacy
        case "fingerprint":                      return Edition.isMaximum ? nil : .privacy
        default:                                 return nil
        }
    }

    private func actionLabel(for id: String) -> String {
        switch id {
        case "ip":          return "Turn on the Searxly VPN"
        case "encryption":  return "Turn on encrypted storage"
        case "adblock":     return "Turn on ad & tracker blocking"
        case "history":     return "Stop saving browsing history"
        case "fingerprint": return "Turn on Maximum Privacy for fingerprint scrambling"
        default:            return "Review this setting"
        }
    }

    private func improveSection(_ suggestions: [PrivacyReport.Protection]) -> some View {
        SettingsSection(
            title: "Raise your score",
            footer: "Each shortcut opens the setting that turns the protection on."
        ) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, p in
                if index > 0 { SettingsDivider() }
                ImproveRow(
                    title: actionLabel(for: p.id),
                    systemImage: p.systemImage,
                    points: p.weight,
                    action: { targetCategory(for: p.id).map { onNavigate?($0) } }
                )
            }
        }
    }

    // MARK: - Protections

    private func protectionsSection(_ report: PrivacyReport) -> some View {
        SettingsSection(
            title: "Protections",
            footer: "Each protection contributes to your score. Searxly can't count individual blocked trackers — WebKit blocks those without reporting a number — so this measures the protections it can verify."
        ) {
            ForEach(Array(report.protections.enumerated()), id: \.element.id) { index, p in
                if index > 0 { SettingsDivider() }
                protectionRow(p)
            }
        }
    }

    private func protectionRow(_ p: PrivacyReport.Protection) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.active ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15))
                .foregroundStyle(p.active ? SettingsTheme.green : SettingsTheme.textTertiary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text(p.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - This session

    private func sessionSection(_ report: PrivacyReport) -> some View {
        SettingsSection(
            title: "This session",
            footer: "Live from the network ledger — how Searxly's own requests left this Mac since launch. Cleared when you quit."
        ) {
            HStack(spacing: 10) {
                statTile("\(report.observedRequests)", "requests\nobserved")
                statTile("\(report.protectedRequests)", "stayed\nprivate",
                         tint: report.protectedRequests > 0 ? SettingsTheme.green : SettingsTheme.textPrimary)
                statTile("\(report.directRequests)", "went\ndirect",
                         tint: report.directRequests == 0 ? SettingsTheme.green : SettingsTheme.warning)
            }

            if !report.laneBreakdown.isEmpty {
                SettingsDivider()
                Text("WHERE THEY WENT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(SettingsTheme.textTertiary)
                ForEach(report.laneBreakdown, id: \.lane) { entry in
                    laneRow(entry.lane, count: entry.count, total: report.observedRequests)
                }
            }

            if report.directRequests > 0 && !Edition.isMaximum {
                Text("Some requests went direct, so those sites saw your IP. Turn on the Searxly VPN to route everything through an encrypted tunnel.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func laneRow(_ lane: EgressLane, count: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(count) / Double(total) : 0
        let tint = lane.isProtected ? SettingsTheme.green : SettingsTheme.warning
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: lane.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .frame(width: 16)
                Text(lane.label)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SettingsTheme.fillStrong)
                    Capsule().fill(tint.opacity(0.5))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
    }

    private func statTile(_ value: String, _ caption: String, tint: Color = SettingsTheme.textPrimary) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 9.5, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(SettingsTheme.textTertiary)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(SettingsTheme.fillFaint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(SettingsTheme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Actionable "raise your score" row

private struct ImproveRow: View {
    let title: String
    let systemImage: String
    let points: Int
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsTheme.fillSubtle)
                        .frame(width: 30, height: 30)
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Spacer(minLength: 8)
                Text("+\(points)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SettingsTheme.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(SettingsTheme.green.opacity(0.12), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SettingsTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hover ? SettingsTheme.cardStrong : SettingsTheme.fillSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(hover ? SettingsTheme.hairlineStrong : SettingsTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in DispatchQueue.main.async { hover = h } }
    }
}
