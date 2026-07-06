//
//  BookmarksHistoryToolbarControl.swift
//  Searxly
//
//  Opens the Bookmarks & History sheet directly (Full Page is chosen inside the sheet).
//

import SwiftUI

/// Unified bookmarks & history control — replaces separate bookmark + history header buttons.
/// Matches `FlatIconButton` sizing in the header toolbar (26×26 icon, 5pt padding).
struct BookmarksHistoryToolbarControl: View {
    @Binding var showingBookmarks: Bool

    var iconSize: CGFloat = 15
    var frameSize: CGFloat = 26
    var padding: CGFloat = 5

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var usesHeaderMetrics: Bool {
        iconSize == 15 && frameSize == 26 && padding == 5
    }

    var body: some View {
        Button {
            showingBookmarks = true
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(padding)
        .frame(width: frameSize + padding * 2, height: frameSize + padding * 2)
        .background(hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Bookmarks & History")
    }

    private var hoverFill: Color {
        guard isHovering else { return .clear }
        return AdaptiveChrome.fill(colorScheme, dark: 0.065, light: 0.05)
    }
}