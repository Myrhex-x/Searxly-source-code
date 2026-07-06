//
//  BookmarksBarView.swift
//  Searxly
//
//  Optional, toggleable favorites bar that sits under the header (View ▸ Show Bookmarks Bar, ⌘⇧B).
//  A horizontal, scrollable row of bookmark chips (favicon + title). Click to open; right-click for
//  Open in New Tab / Remove. Reads bookmarks from BrowserState; removals mutate the bound array so the
//  existing onChange persists them.
//

import SwiftUI

struct BookmarksBarView: View {
    let bookmarks: [BookmarkItem]
    let glassEnabled: Bool
    let onOpen: (URL) -> Void
    let onOpenInNewTab: (URL) -> Void
    let onRemove: (BookmarkItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                // bookmarks are stored newest-first (insert at index 0), so iterate as-is to keep the
                // most-recently-added bookmark at the visible left edge.
                ForEach(bookmarks) { bookmark in
                    if let url = URL(string: bookmark.url) {
                        BookmarkBarChip(
                            bookmark: bookmark,
                            onOpen: { onOpen(url) },
                            onOpenInNewTab: { onOpenInNewTab(url) },
                            onRemove: { onRemove(bookmark) }
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .background(
            glassEnabled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial)
        )
    }
}

private struct BookmarkBarChip: View {
    let bookmark: BookmarkItem
    let onOpen: () -> Void
    let onOpenInNewTab: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    private var displayTitle: String {
        if !bookmark.title.isEmpty { return bookmark.title }
        return URL(string: bookmark.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? bookmark.url
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                FaviconView(pageURL: bookmark.url, size: 15, cornerRadius: 3)
                Text(displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(bookmark.url)
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Open in New Tab", action: onOpenInNewTab)
            Divider()
            Button("Remove from Bookmarks", role: .destructive, action: onRemove)
        }
    }
}
