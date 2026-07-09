//
//  NetworkLedgerView.swift
//  Searxly
//
//  The in-app Network Ledger: a live, readable view of how Searxly's own traffic leaves the device,
//  so "nothing leaks in Maximum Privacy" is something the user can WATCH, not just trust. Renders the
//  RAM-only NetworkEgressLedger — a status header (where each class of traffic goes right now) plus a
//  rolling log of recent navigations and blocked attempts. Nothing here is persisted or sent anywhere.
//

import SwiftUI

/// Drop-in settings section showing the live egress lanes + recent activity.
struct NetworkLedgerSection: View {
    private let ledger = NetworkEgressLedger.shared

    var body: some View {
        SettingsSection(
            title: "Network activity",
            footer: "A live record of how Searxly's own traffic leaves this Mac — kept in memory only, never written to disk or sent anywhere. It shows this app's page loads and blocked attempts; it isn't a system-wide monitor."
        ) {
            leakSummary

            SettingsDivider()

            ForEach(ledger.liveLanes) { lane in
                laneStatusRow(lane)
            }

            SettingsDivider()

            recentActivity
        }
    }

    // MARK: - Leak summary

    private var leakSummary: some View {
        let leaked = ledger.leakedCount
        return HStack(spacing: 10) {
            Image(systemName: leaked == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(leaked == 0 ? SettingsTheme.green : SettingsTheme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(leaked == 0 ? "No request has left your real IP" : "\(leaked) request\(leaked == 1 ? "" : "s") used a direct connection")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text(leaked == 0
                     ? "Every recorded request rode Tor, stayed on loopback, or was blocked."
                     : "Direct connections only happen outside Maximum Privacy.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Live lane status

    private func laneStatusRow(_ lane: EgressLaneStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: lane.lane.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint(for: lane.lane))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(lane.id)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text(lane.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            laneBadge(lane.lane)
        }
    }

    // MARK: - Recent activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(SettingsTheme.textTertiary)
                Spacer()
                if !ledger.events.isEmpty {
                    Button("Clear") { ledger.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            }

            if ledger.events.isEmpty {
                Text("No activity yet. Browse or search and it'll appear here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textTertiary)
            } else {
                // Most recent first, capped so the section stays compact.
                ForEach(ledger.events.suffix(14).reversed()) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: EgressEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.lane.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint(for: event.lane))
                .frame(width: 15)
            Text(event.host)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(event.kind)
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.textTertiary)
            Spacer(minLength: 6)
            laneBadge(event.lane)
            Text(Self.relative(event.at))
                .font(.system(size: 10))
                .foregroundStyle(SettingsTheme.textTertiary)
                .monospacedDigit()
        }
    }

    // MARK: - Bits

    private func laneBadge(_ lane: EgressLane) -> some View {
        Text(lane.label)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(tint(for: lane))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint(for: lane).opacity(0.12), in: Capsule())
    }

    private func tint(for lane: EgressLane) -> Color {
        switch lane {
        case .tor, .loopback, .vpn: return SettingsTheme.green   // protected / live status
        case .blocked, .suppressed: return SettingsTheme.textTertiary
        case .direct:               return SettingsTheme.warning // only outside Maximum Privacy
        }
    }

    private static func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 2 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
