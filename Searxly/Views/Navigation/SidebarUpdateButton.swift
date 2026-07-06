//
//  SidebarUpdateButton.swift
//  Searxly
//
//  Persistent "Update available" control for the left sidebar. Appears only when Sparkle has found a
//  new signed version (SoftwareUpdater.updateAvailable). Deliberately a chunky, hard-to-miss card so
//  users actually notice — monochrome + the one status green (per brand), with a gentle breathing glow.
//  Tapping brings the install flow into focus.
//

import SwiftUI

struct SidebarUpdateButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let isCollapsed: Bool
    let version: String?
    let action: () -> Void

    @State private var hovered = false
    @State private var pulse = false

    private var green: Color { SERPDesign.accentGreen }

    var body: some View {
        Button(action: action) {
            (isCollapsed ? AnyView(collapsed) : AnyView(card))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(version.map { "Searxly \($0) is available — click to update" } ?? "A new version is available — click to update")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Expanded: a big, obvious card

    private var card: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(green.opacity(0.22)).frame(width: 36, height: 36)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(green)
            }
            VStack(spacing: 2) {
                Text("Update available")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(green)
                Text(version.map { "Version \($0) · click to install" } ?? "Click to install")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(green.opacity(hovered ? 0.22 : 0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(green.opacity(pulse ? 0.65 : 0.32), lineWidth: 1.5)
        )
        .shadow(color: green.opacity(pulse ? 0.28 : 0.06), radius: pulse ? 9 : 4)
    }

    // MARK: - Collapsed: a prominent square badge

    private var collapsed: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(green.opacity(hovered ? 0.28 : 0.18))
                .frame(width: 36, height: 36)
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(green)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(green.opacity(pulse ? 0.65 : 0.32), lineWidth: 1.5)
                .frame(width: 36, height: 36)
        )
        .shadow(color: green.opacity(pulse ? 0.28 : 0.06), radius: pulse ? 7 : 3)
        .frame(maxWidth: .infinity)
    }
}
