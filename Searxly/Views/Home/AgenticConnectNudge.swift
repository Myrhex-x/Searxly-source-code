//
//  AgenticConnectNudge.swift
//  Searxly
//
//  A one-time, dismissible hint on the home screen that points new users to connect their AI (Agentic
//  Tools), so the feature is discoverable without opening the ☰ menu. Shows only while Agentic Tools has
//  never been turned on and the user hasn't dismissed it — then it's gone for good.
//
//  Chrome: the shared floating-panel surface (the sidebar / knowledge-card material) rather than a bare
//  material capsule, so it reads as the same object family as the rest of the app and sits correctly on
//  any canvas — including Maximum's pitch black, where a plain material pill looked like it was floating
//  on nothing. The CTA is the app's monochrome ink pill (SettingsTheme.inkFill / .onInk, as used by
//  Settings, the privacy report and Tor bridges); `.borderedProminent` was tinting it system blue, which
//  is off-brand in an app whose accents are only ever status or Maximum's ember.
//

import SwiftUI

struct AgenticConnectNudge: View {
    @AppStorage("Searxly.AgenticNudgeDismissed") private var dismissed = false
    var manager = AgenticServerManager.shared
    /// Opens the Agentic Tools settings (the connect flow).
    var onConnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var connectHovering = false
    @State private var closeHovering = false

    var body: some View {
        Group {
            if !dismissed && !manager.isEnabled {
                HStack(spacing: 12) {
                    iconWell

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect your AI")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        Text("Let Claude — or any local AI — search and browse through Searxly.")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }

                    Spacer(minLength: 4)

                    connectButton
                    closeButton
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .searxlyFloatingPanel(cornerRadius: 16, elevation: 0.8)
                .frame(maxWidth: 520)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: dismissed)
    }

    /// The mark sits in its own well so the row has a clear anchor instead of a loose glyph.
    private var iconWell: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SettingsTheme.textPrimary)
            .frame(width: 28, height: 28)
            .background(SettingsTheme.fillSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SettingsTheme.hairline, lineWidth: 0.7)
            )
    }

    private var connectButton: some View {
        Button { onConnect() } label: {
            Text("Connect")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.onInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SettingsTheme.inkFill.opacity(connectHovering ? 0.88 : 1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { connectHovering = hovering }
        }
        .accessibilityLabel(Text("Connect your AI"))
    }

    private var closeButton: some View {
        Button { withAnimation { dismissed = true } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(closeHovering ? SettingsTheme.textPrimary : SettingsTheme.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(closeHovering ? SettingsTheme.fillSubtle : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { closeHovering = hovering }
        }
        .help("Dismiss")
        .accessibilityLabel(Text("Dismiss"))
    }
}
