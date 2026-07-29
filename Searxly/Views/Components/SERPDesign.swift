//
//  SERPDesign.swift
//  Searxly
//
//  Shared design tokens and liquid-glass SERP chrome (tabs, header buttons).
//

import SwiftUI

enum SERPDesign {
    static let accentGreen = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let linkBlue = Color(red: 0.533, green: 0.808, blue: 1.0)

    /// Broadcast "live" red — the news-urgency accent (LIVE / BREAKING / sub-hour timestamps). Scoped to
    /// news; green stays the meaning color for wallet/price. Brighter in dark for pop, deeper in light.
    static let liveRed = AdaptiveChrome.dynamic(
        light: Color(red: 0.80, green: 0.09, blue: 0.07),
        dark: Color(red: 1.0, green: 0.27, blue: 0.23)
    )
    static let maxListWidth: CGFloat = 720
    static let knowledgePanelWidth: CGFloat = 360
    static let knowledgePanelSpacing: CGFloat = 24
    /// ~list + panel + padding; kept modest so cards still appear on 13" windows with peeker rail.
    static let minWidthForKnowledgePanel: CGFloat = 920
    static let knowledgePanelMinContentHeight: CGFloat = 520
    static let knowledgePanelCornerRadius: CGFloat = 12
    static let resultSpacing: CGFloat = 4
    static let listHorizontalPadding: CGFloat = 16

    static func linkColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? linkBlue : Color(red: 0.05, green: 0.38, blue: 0.82)
    }
}

// MARK: - Liquid glass capsule (category tabs + chips)

private struct SERPGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool
    let glassEnabled: Bool

    func body(content: Content) -> some View {
        content
            // Solid panel canvas — the SAME surface the floating sidebar uses, so the tabs/pills read at
            // the sidebar's darkness instead of a light frosted material. A subtle wash lifts the pill
            // off the same-colored SERP canvas (more when selected); a hairline + seat shadow define its
            // edge — exactly how the sidebar stays legible against the same canvas behind it.
            .background(
                ZStack {
                    Capsule().fill(AdaptiveChrome.panelCanvas)
                    Capsule().fill(AdaptiveChrome.fill(
                        colorScheme,
                        dark: isSelected ? 0.12 : 0.045,
                        light: isSelected ? 0.10 : 0.05
                    ))
                }
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected
                        ? AdaptiveChrome.border(colorScheme, dark: 0.20, light: 0.16)
                        : AdaptiveChrome.border(colorScheme, dark: 0.10, light: 0.09),
                    lineWidth: isSelected ? 1 : 0.75
                )
            )
            .shadow(
                color: AdaptiveChrome.shadow(colorScheme, darkOpacity: isSelected ? 0.28 : 0.18),
                radius: isSelected ? 4 : 2,
                x: 0,
                y: 1
            )
    }
}

extension View {
    func serpGlassCapsule(isSelected: Bool, glassEnabled: Bool) -> some View {
        modifier(SERPGlassCapsuleModifier(isSelected: isSelected, glassEnabled: glassEnabled))
    }
}

// MARK: - Category tabs

struct SERPCategoryTabs: View {
    let categories: [(label: String, value: String?)]
    let selected: String?
    let glassEnabled: Bool
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.label) { item in
                    let isSelected = selected == item.value || (selected == nil && item.value == nil)
                    Button {
                        onSelect(item.value)
                    } label: {
                        Text(item.label)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .serpGlassCapsule(isSelected: isSelected, glassEnabled: glassEnabled)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Header action buttons

struct SERPGlassIconButton: View {
    let systemName: String
    let glassEnabled: Bool
    var size: CGFloat = 30
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .glassIcon(size: size, glassEnabled: glassEnabled)
        .help(help ?? "")
    }
}

struct SERPGlassChipButton: View {
    let title: String
    let systemImage: String?
    let glassEnabled: Bool
    var isProminent: Bool = false
    var tint: Color = SERPDesign.accentGreen
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.caption.weight(.medium))
        }
        .glassPill(isProminent: isProminent, tint: tint, glassEnabled: glassEnabled)
    }
}

// MARK: - Result row chrome

struct SERPResultRowChrome<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let glassEnabled: Bool
    let isHighlighted: Bool
    let isHovering: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background {
                if isHovering || isHighlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.04 : 0.025))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .opacity(glassEnabled ? 0.55 : 0.35)
                        )
                        .searxlyGlass(
                            glassEnabled ? .interactive : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
            }
            .overlay(alignment: .leading) {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(SERPDesign.accentGreen.opacity(0.55))
                        .frame(width: 3)
                        .padding(.vertical, 6)
                }
            }
    }
}