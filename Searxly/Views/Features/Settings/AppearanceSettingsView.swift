//
//  AppearanceSettingsView.swift
//  Searxly
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var reduceLiquidGlass: Bool
    @Binding var appearanceModeRaw: String

    @AppStorage("homeStarsEnabled") private var homeStarsEnabled = true

    private var selectedMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: Localization.string("appearance_title", defaultValue: "Appearance"),
                subtitle: "Theme and visual effects."
            )

            SettingsSection(
                title: "Theme",
                footer: Localization.string("theme_description")
            ) {
                HStack(spacing: 10) {
                    ForEach(AppearanceMode.allCases) { mode in
                        AppearanceModeCard(
                            mode: mode,
                            isSelected: selectedMode == mode
                        ) {
                            appearanceModeRaw = mode.rawValue
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            SettingsSection(title: "Effects") {
                SettingsToggleRow(
                    title: Localization.string("reduce_liquid_glass"),
                    description: Localization.string("reduce_liquid_glass_description"),
                    isOn: $reduceLiquidGlass
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Animated stars on home",
                    description: "A subtle starfield behind the home page. Independent of liquid glass.",
                    isOn: $homeStarsEnabled
                )
            }

        }
    }
}

// MARK: - Theme cards

private struct AppearanceModeCard: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(previewGradient)
                        .frame(height: 54)
                        .overlay(alignment: .topTrailing) {
                            if mode == .system {
                                Circle()
                                    .fill(Color.primary.opacity(0.18))
                                    .frame(width: 14, height: 14)
                                    .offset(x: -8, y: 8)
                            }
                        }

                    Image(systemName: mode.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(previewIconColor)
                        .shadow(color: .black.opacity(mode == .light ? 0.08 : 0), radius: 2, y: 1)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

                VStack(spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)

                    Text(mode.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.12)
                            : (isHovering ? Color.white.opacity(0.05) : Color.white.opacity(0.025))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.7) : Color.white.opacity(0.1),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private var previewGradient: LinearGradient {
        switch mode {
        case .system:
            return LinearGradient(
                colors: [Color(white: 0.94), Color(white: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .light:
            return LinearGradient(
                colors: [Color(white: 0.98), Color(white: 0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .dark:
            return LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var previewIconColor: Color {
        switch mode {
        case .system: return .white
        case .light:  return Color(white: 0.25)
        case .dark:   return .white.opacity(0.9)
        }
    }
}