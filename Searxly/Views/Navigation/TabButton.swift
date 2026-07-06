//
//  TabButton.swift
//  Searxly
//

import SwiftUI
import WebKit

enum TabButtonStyle {
    case horizontalGlass
    case sidebarCompact
}

struct TabButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let tab: BrowserTab
    let isSelected: Bool
    let isHovered: Bool
    let glassEnabled: Bool
    let toolbarMaterial: Material
    let style: TabButtonStyle

    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            switch style {
            case .horizontalGlass:
                horizontalGlassBody
            case .sidebarCompact:
                sidebarCompactBody
            }
        }
        .contentShape(Rectangle())
        // Use a *simultaneous* tap (not .onTapGesture) so it doesn't exclusively claim the press — the
        // sidebar row's .onDrag needs the same press to start a drag. A real tap (down+up without moving)
        // still selects; a press-and-drag begins a reorder instead.
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .shadow(
            color: isSelected && style == .horizontalGlass
                ? AdaptiveChrome.shadow(colorScheme, darkOpacity: 0.1)
                : .clear,
            radius: 4, x: 0, y: 1
        )
    }

    // MARK: - Horizontal glassy pill style (top tab bar)

    private var horizontalGlassBody: some View {
        HStack(spacing: 8) {
            tabIcon(size: 16, cornerRadius: 4)

            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 135, alignment: .leading)

            if isSelected || isHovered {
                closeButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? (glassEnabled ? .thickMaterial : .regularMaterial)
                : .thinMaterial,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .searxlyGlass(
            isSelected && glassEnabled ? .interactive : .clear,
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isSelected
                        ? AdaptiveChrome.border(colorScheme, dark: 0.22)
                        : AdaptiveChrome.border(colorScheme, dark: 0.06),
                    lineWidth: isSelected ? 1.0 : 0.5
                )
        )
        .scaleEffect(isSelected ? 1.015 : (isHovered ? 1.0 : 0.985))
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isSelected)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovered)
    }

    // MARK: - Sidebar list row

    private var sidebarCompactBody: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                tabIcon(size: 18, cornerRadius: 4)

                if tab.isPrivate {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.4))
                        .offset(x: 4, y: -4)
                }
            }

            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected || isHovered {
                closeButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                // Fill-only selection (no stroke outline). The outline's top segment used to read as a
                // hard "line" directly under a section header when the selected tab was the first row.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.10 : 0.07))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.thinMaterial)
                            .opacity(glassEnabled ? 0.55 : 0.35)
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.04))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isHovered)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isSelected)
    }

    @ViewBuilder
    private func tabIcon(size: CGFloat, cornerRadius: CGFloat) -> some View {
        if tab.kind.isUtility {
            Image(systemName: tab.kind.utilityIcon)
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else {
            FaviconView(
                pageURL: tab.pageURLString,
                size: size,
                cornerRadius: cornerRadius,
                loadRemote: !tab.isPrivate
            )
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close tab")
        .accessibilityLabel(Text("Close tab"))
    }
}