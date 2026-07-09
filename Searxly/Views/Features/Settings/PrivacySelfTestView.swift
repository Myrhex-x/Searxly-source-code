//
//  PrivacySelfTestView.swift
//  Searxly
//
//  UI for the one-tap privacy self-test (see PrivacySelfTest). Shows each check with a live pass /
//  warn / fail state, headlined by the active "your real IP is hidden" verification over Tor.
//

import SwiftUI

struct PrivacySelfTestSection: View {
    private let test = PrivacySelfTest.shared

    var body: some View {
        SettingsSection(
            title: "Privacy self-test",
            footer: "Verifies the live posture and actively confirms your exit IP is a Tor node. The test's own requests ride the same fail-closed Tor lane as the app — if Tor isn't up, the live IP check can't run (and can't leak)."
        ) {
            headerRow

            if !test.checks.isEmpty {
                SettingsDivider()
                ForEach(test.checks) { check in
                    checkRow(check)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            summaryIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(summaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                if let lastRun = test.lastRun, !test.running {
                    Text("Last run \(Self.relative(lastRun)) ago")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await test.run() }
            } label: {
                HStack(spacing: 6) {
                    if test.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(test.running ? "Testing…" : (test.checks.isEmpty ? "Run self-test" : "Re-run"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(SettingsTheme.inkFill, in: Capsule())
                .foregroundStyle(SettingsTheme.onInk)
            }
            .buttonStyle(.plain)
            .disabled(test.running)
        }
    }

    private func checkRow(_ check: PrivacySelfTest.Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stateIcon(check.state)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Summary

    private var summaryTitle: String {
        switch test.verdict {
        case .pending: return "Confirm your privacy is working"
        case .running: return "Running privacy self-test…"
        case .pass:    return "All checks passed — you're protected"
        case .warn:    return "Protected, with notes to review"
        case .fail:    return "Attention needed — a check failed"
        }
    }

    private var summaryIcon: some View {
        Group {
            switch test.verdict {
            case .pending: Image(systemName: "checkmark.shield").foregroundStyle(SettingsTheme.textSecondary)
            case .running: ProgressView().controlSize(.small)
            case .pass:    Image(systemName: "checkmark.shield.fill").foregroundStyle(SettingsTheme.green)
            case .warn:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SettingsTheme.warning)
            case .fail:    Image(systemName: "xmark.shield.fill").foregroundStyle(SettingsTheme.danger)
            }
        }
        .font(.system(size: 15, weight: .semibold))
    }

    @ViewBuilder
    private func stateIcon(_ state: PrivacySelfTest.Check.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(SettingsTheme.textTertiary)
        case .running: ProgressView().controlSize(.small)
        case .pass:    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(SettingsTheme.green)
        case .warn:    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(SettingsTheme.warning)
        case .fail:    Image(systemName: "xmark.octagon.fill").font(.system(size: 13)).foregroundStyle(SettingsTheme.danger)
        }
    }

    private static func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(max(1, s))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
