//
//  ListItemRow.swift
//  Searxly
//
//  Small reusable row for bookmarks and recent history inside the sheet.
//

import SwiftUI

struct ListItemRow: View {
    let title: String
    let url: String
    let icon: String
    let iconColor: Color
    var glassEnabled: Bool = true

    let onOpen: () -> Void
    let onDelete: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22, height: 22)
                        .background(
                            iconColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red.opacity(isHovering ? 0.85 : 0.55))
                        .frame(width: 28, height: 28)
                        .background(
                            Color.red.opacity(isHovering ? 0.1 : 0.05),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .searxlyGlass(
            glassEnabled && isHovering ? .interactive : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    AdaptiveChrome.border(
                        colorScheme,
                        dark: isHovering ? 0.1 : 0.05,
                        light: isHovering ? 0.1 : 0.06
                    ),
                    lineWidth: 0.55
                )
        )
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(glassEnabled ? .ultraThinMaterial : .regularMaterial)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isHovering
                            ? AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03)
                            : AdaptiveChrome.fill(colorScheme, dark: 0.02, light: 0.015)
                    )
            }
    }
}