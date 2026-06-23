//
//  OnboardingLocalSearchStep.swift
//  Searxly
//

import AppKit
import SwiftUI

struct OnboardingLocalSearchStep: View {
    @Bindable var setup: OnboardingSetupController

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            OnboardingStepHero(
                icon: "server.rack",
                title: "Set up local search",
                subtitle: "Spin up a private SearXNG instance on this Mac. Your queries stay here — nothing goes to any server."
            )

            localSearchStatusCard

            if let status = setup.connectionStatus {
                OnboardingInsetCard(isSelected: setup.isConnectionSuccessful) {
                    Text(status)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(setup.isConnectionSuccessful ? .primary : .secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }

            if setup.isConnectionSuccessful {
                OnboardingInsetCard(isSelected: true) {
                    Text("Your searches are now private.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 10) {
                OnboardingActionCard(title: "Open folder", systemImage: "folder") {
                    LocalSearxngManager.shared.openProjectFolderInFinder()
                }
                OnboardingActionCard(
                    title: "Test connection",
                    systemImage: "arrow.triangle.2.circlepath",
                    disabled: setup.isTestingConnection
                ) {
                    setup.useLocalAndTest(quick: true)
                }
            }

            DisclosureGroup("Troubleshooting") {
                VStack(alignment: .center, spacing: 10) {
                    let recentLogs = Array(setup.localSearxng.logs.suffix(6))
                    if recentLogs.isEmpty {
                        Text("No logs yet. Tap Start local search to begin.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        OnboardingInsetCard {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(recentLogs.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .frame(maxHeight: 80)
                        }

                        OnboardingActionCard(title: "Clear logs", systemImage: "trash") {
                            setup.localSearxng.clearLogs()
                        }
                    }

                    HStack(spacing: 10) {
                        OnboardingActionCard(title: "Create folder", systemImage: "folder.badge.plus") {
                            Task { _ = try? await LocalSearxngManager.shared.provisionIfNeeded() }
                        }
                        OnboardingActionCard(title: "Rebuild fresh", systemImage: "arrow.clockwise") {
                            Task { await LocalSearxngManager.shared.recreateProjectFolder() }
                        }
                    }

                    OnboardingInsetCard {
                        HStack(spacing: 8) {
                            TextField("Custom URL", text: $setup.newInstanceURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            OnboardingActionCard(
                                title: "Test & use",
                                systemImage: "checkmark.circle",
                                disabled: setup.isTestingConnection
                            ) {
                                setup.useLocalAndTest()
                            }
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private var localSearchStatusCard: some View {
        let mgr = setup.localSearxng
        return OnboardingInsetCard(isSelected: setup.isConnectionSuccessful) {
            VStack(alignment: .center, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: statusIcon(for: mgr))
                        .foregroundStyle(setup.isConnectionSuccessful ? Color.green : .secondary)

                    Text(statusSummary(for: mgr))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if setup.isTestingConnection {
                        ProgressView().scaleEffect(0.65)
                    }
                }

                if let err = mgr.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func statusIcon(for mgr: LocalSearxngManager) -> String {
        if case .error = mgr.status { return "exclamationmark.triangle.fill" }
        if setup.isConnectionSuccessful { return "checkmark.seal.fill" }
        if mgr.status == .starting || mgr.isBusy { return "hourglass" }
        if mgr.status == .stopped { return "powerplug" }
        return "circle"
    }

    private func statusSummary(for mgr: LocalSearxngManager) -> String {
        if setup.isConnectionSuccessful {
            return "Private SearXNG ready on this Mac"
        }
        switch mgr.status {
        case .running:
            return "Local SearXNG detected — tap Start local search to connect"
        case .starting:
            return "SearXNG is starting…"
        case .stopping:
            return "Stopping SearXNG…"
        case .stopped:
            return "Tap Start local search to launch your private instance"
        case .error(let msg):
            return "Setup error: \(msg)"
        }
    }
}