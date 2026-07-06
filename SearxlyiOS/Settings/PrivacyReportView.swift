//
//  PrivacyReportView.swift
//  SearxlyiOS
//
//  The full privacy dashboard: lifetime blocked-tracker count plus the top tracker companies
//  the shields caught, ranked with monochrome bars. Counts only ever name TRACKER domains
//  (doubleclick.net, …) — never the sites the user visited.
//

import SwiftUI

struct PrivacyReportView: View {
    private var shields = ShieldSettings.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Brand.textSecondary)
                    Text(shields.lifetimeTrackersBlocked.formatted())
                        .font(.system(size: 40, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Brand.text)
                    Text("tracking requests blocked")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowBackground(Color.clear)
            }

            if !shields.topTrackers.isEmpty {
                Section("Top Trackers Blocked") {
                    let top = Array(shields.topTrackers.prefix(12))
                    let maxCount = max(top.first?.count ?? 1, 1)
                    ForEach(top, id: \.domain) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.domain)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.count.formatted())
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Brand.textSecondary)
                            }
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Brand.text.opacity(0.85))
                                    .frame(width: max(4, geo.size.width * CGFloat(entry.count) / CGFloat(maxCount)),
                                           height: 4)
                            }
                            .frame(height: 4)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Section {
                Button("Reset Statistics", role: .destructive) { shields.resetStats() }
                    .disabled(shields.lifetimeTrackersBlocked == 0)
            } footer: {
                Text("Counted on-device from tracker requests attempted against pages you visited while shields were up — an undercount of what the filter lists actually block. Nothing here ever leaves this device.")
            }
        }
        .navigationTitle("Privacy Report")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }
}
