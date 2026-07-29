//
//  PrivacyReportView.swift
//  SearxlyiOS
//
//  Lifetime blocked-tracker count plus top tracker domains the shields caught. Counts only ever
//  name TRACKER domains — never the sites the user visited.
//

import SwiftUI

struct PrivacyReportView: View {
    private var shields = ShieldSettings.shared
    private var locale = AppLocale.shared

    var body: some View {
        let _ = locale.languageCode
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .scaledFont(size: 26, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                    Text(shields.lifetimeTrackersBlocked.formatted())
                        .scaledFont(size: 40, weight: .bold).monospacedDigit()
                        .foregroundStyle(Brand.text)
                        .contentTransition(.numericText())
                    Text(L("tracking requests blocked"))
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowBackground(Color.clear)
            }

            if !shields.topTrackers.isEmpty {
                Section(L("Top Trackers Blocked")) {
                    let top = Array(shields.topTrackers.prefix(12))
                    let maxCount = max(top.first?.count ?? 1, 1)
                    ForEach(top, id: \.domain) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.domain)
                                    .scaledFont(size: 14, weight: .medium)
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.count.formatted())
                                    .scaledFont(size: 13, weight: .semibold).monospacedDigit()
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
                Button(L("Reset Statistics"), role: .destructive) { shields.resetStats() }
                    .disabled(shields.lifetimeTrackersBlocked == 0)
            } footer: {
                Text(L("Counted on-device from tracker requests attempted against pages you visited while shields were up — an undercount of what the filter lists actually block. Nothing here ever leaves this device."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(L("Privacy Report"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
        .preferredColorScheme(.dark)
    }
}
