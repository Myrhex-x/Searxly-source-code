//
//  AIStatusPill.swift
//  Searxly
//
//  NEW FILE (Phase 0).
//  Small, calm status indicator for Searxly Agent readiness.
//  Follows the existing pill / badge language used for local SearXNG / instance status.
//  Only visible when the user has ever enabled the master toggle (or in Developer mode).
//

import SwiftUI

struct AIStatusPill: View {
    // LocalIntelligenceManager is @Observable (new Observation framework).
    // For a singleton we read the shared instance directly; SwiftUI will track accesses.
    private var manager: LocalIntelligenceManager { LocalIntelligenceManager.shared }
    let compact: Bool

    var body: some View {
        let status = manager.status
        let isOn = manager.isEnabled

        if !isOn && !DeveloperSettings.shared.isEnabled {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 6, height: 6)

                Text(label(for: status))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .background(
                (glassEnabled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.primary.opacity(0.04)))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .help(manager.statusDescription)
        }
    }

    private var glassEnabled: Bool {
        // Read the same @AppStorage used by the rest of the app (ContentView).
        // We avoid direct dependency by reading the default.
        !UserDefaults.standard.bool(forKey: "reduceLiquidGlass")
    }

    private func color(for status: LocalAIStatus) -> Color {
        switch status {
        case .ready, .generating: return .green
        case .disabled: return .gray
        case .checking, .unloading: return .orange
        case .unavailable, .error: return .red
        }
    }

    private func label(for status: LocalAIStatus) -> String {
        switch status {
        case .ready: return "Searxly Agent"
        case .generating: return "Searxly Agent • working"
        case .disabled: return "Agent off"
        default: return "Searxly Agent"
        }
    }
}