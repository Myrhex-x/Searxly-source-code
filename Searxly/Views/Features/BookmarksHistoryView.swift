//
//  BookmarksHistoryView.swift
//  Searxly
//
//  Bookmarks & History sheet and full-page view.
//

import SwiftUI

// MARK: - Date grouping helpers

private struct HistoryDateGroup: Identifiable {
    let id: String
    let label: String
    let items: [HistoryItem]
}

private func groupHistory(_ items: [HistoryItem]) -> [HistoryDateGroup] {
    let cal = Calendar.current
    let now = Date()
    let todayStart = cal.startOfDay(for: now)
    let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
    let weekStart = cal.date(byAdding: .day, value: -7, to: todayStart)!

    let sorted = items.sorted { $0.date > $1.date }

    var groups: [HistoryDateGroup] = []
    let today = sorted.filter { $0.date >= todayStart }
    let yesterday = sorted.filter { $0.date >= yesterdayStart && $0.date < todayStart }
    let thisWeek = sorted.filter { $0.date >= weekStart && $0.date < yesterdayStart }
    let older = sorted.filter { $0.date < weekStart }
    if !today.isEmpty     { groups.append(.init(id: "today",     label: "Today",     items: today)) }
    if !yesterday.isEmpty { groups.append(.init(id: "yesterday", label: "Yesterday", items: yesterday)) }
    if !thisWeek.isEmpty  { groups.append(.init(id: "week",      label: "This Week", items: thisWeek)) }
    if !older.isEmpty     { groups.append(.init(id: "older",     label: "Older",     items: older)) }
    return groups
}

// MARK: - View

struct BookmarksHistoryView: View {
    @Binding var bookmarks: [BookmarkItem]
    @Binding var history: [HistoryItem]
    @Binding var searchText: String
    @Binding var showingBookmarks: Bool

    let loadInWebView: (URL) -> Void

    var isFullPage: Bool = false
    var glassEnabled: Bool = true

    var onCloseFullPage: (() -> Void)? = nil
    var onRequestFullHistory: (() -> Void)? = nil
    /// Opens the unified "Import Data" hub (bookmarks + passwords). Falls back to nothing if unset.
    var onOpenImport: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    @State private var filterText: String = ""

    private var historyEnabled: Bool {
        PrivacyManager.shared.historyEnabled
    }

    private var filteredBookmarks: [BookmarkItem] {
        guard !filterText.isEmpty else { return bookmarks }
        let q = filterText.lowercased()
        return bookmarks.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    private var filteredHistory: [HistoryItem] {
        guard !filterText.isEmpty else { return history }
        let q = filterText.lowercased()
        return history.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if isFullPage {
                fullPageBody
            } else {
                sheetBody
            }
        }
        .frame(maxWidth: isFullPage ? .infinity : 540, maxHeight: isFullPage ? .infinity : 520)
        .background(pageBackground)
    }

    // MARK: - Full page

    private var fullPageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                fullPageHeader
                filterField
                bookmarksSection
                fullPageHistorySection
                footerActions
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var fullPageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06, light: 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.14), lineWidth: 1)
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.primary.opacity(0.68))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Bookmarks & History")
                    .font(.title.weight(.semibold))
                Text("Manage saved pages and browsing history")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // Group the trailing actions in their own HStack so they center-align with each other.
            // (The parent header HStack is .top-aligned; left to the parent the two buttons would pin
            // to the top and their differently-sized SF Symbols would render at different heights.)
            HStack(spacing: 8) {
                Button {
                    onOpenImport?()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onCloseFullPage?()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Sheet

    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Rectangle()
                .fill(AdaptiveChrome.divider(colorScheme))
                .frame(height: 1)

            filterField
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    bookmarksSection
                    sheetHistorySection
                    footerActions
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                monochromeIconBox("bookmark.fill", size: 32, iconSize: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Bookmarks & History")
                        .font(.headline.weight(.semibold))
                    Text("Saved pages and recent visits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                headerActionButton(title: "Import", icon: "square.and.arrow.down") {
                    onOpenImport?()
                }

                if onRequestFullHistory != nil {
                    headerActionButton(title: "Full Page", icon: "rectangle.expand.vertical") {
                        onRequestFullHistory?()
                    }
                }

                headerActionButton(title: "Done", icon: "checkmark") {
                    showingBookmarks = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func monochromeIconBox(_ icon: String, size: CGFloat, iconSize: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.primary.opacity(0.68))
            .frame(width: size, height: size)
            .background(
                AdaptiveChrome.fill(colorScheme, dark: 0.06, light: 0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 0.6)
            )
    }

    private func headerActionButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 88, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: - Filter field (used in both modes)

    @ViewBuilder
    private var filterField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter bookmarks and history…", text: $filterText)
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if glassEnabled {
                shape.fill(.ultraThinMaterial)
            } else {
                shape.fill(AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 1)
        )
    }

    // MARK: - Bookmarks section (shared)

    @ViewBuilder
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: isFullPage ? 10 : 8) {
            sectionHeader("Bookmarks", count: filteredBookmarks.count)

            if filteredBookmarks.isEmpty {
                emptyNote(
                    !filterText.isEmpty
                        ? "No bookmarks match your filter."
                        : "No bookmarks yet."
                )
            } else {
                sectionCard {
                    VStack(spacing: 6) {
                        ForEach(filteredBookmarks) { item in
                            ListItemRow(
                                title: item.title,
                                url: item.url,
                                icon: "star.fill",
                                iconColor: colorScheme == .dark ? Color.white.opacity(0.72) : Color.primary.opacity(0.62),
                                glassEnabled: glassEnabled,
                                onOpen: { openItem(urlString: item.url) },
                                onDelete: {
                                    bookmarks.removeAll { $0.id == item.id }
                                    Persistence.saveBookmarks(bookmarks)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - History: grouped (full page)

    @ViewBuilder
    private var fullPageHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                sectionHeader(
                    "History",
                    count: filteredHistory.count
                )
                if !historyEnabled {
                    Text("recording off")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AdaptiveChrome.fill(colorScheme, dark: 0.04), in: Capsule())
                }
            }

            if !historyEnabled && filteredHistory.isEmpty {
                emptyNote("History recording is turned off in Settings → Privacy & Data.")
            } else if filteredHistory.isEmpty {
                emptyNote(
                    !filterText.isEmpty
                        ? "No history entries match your filter."
                        : "No browsing history yet."
                )
            } else {
                let groups = groupHistory(filteredHistory)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.label.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                            .padding(.horizontal, 2)

                        sectionCard {
                            VStack(spacing: 6) {
                                ForEach(group.items) { item in
                                    historyRow(item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - History: flat recent (sheet)

    @ViewBuilder
    private var sheetHistorySection: some View {
        let recentItems = Array(filteredHistory.suffix(20).reversed())

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionHeader("Recent History", count: recentItems.count)
                if !historyEnabled {
                    Text("recording off")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AdaptiveChrome.fill(colorScheme, dark: 0.04), in: Capsule())
                }
            }

            if !historyEnabled && recentItems.isEmpty {
                emptyNote("History recording is turned off in Settings → Privacy & Data.")
            } else if recentItems.isEmpty {
                emptyNote(
                    !filterText.isEmpty
                        ? "No history entries match your filter."
                        : "No recent history."
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(recentItems) { item in
                        historyRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ item: HistoryItem) -> some View {
        ListItemRow(
            title: item.title,
            url: item.url,
            icon: "clock",
            iconColor: .secondary,
            glassEnabled: glassEnabled,
            onOpen: { openItem(urlString: item.url) },
            onDelete: {
                history.removeAll { $0.id == item.id }
                Persistence.saveHistory(history)
            }
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerActions: some View {
        if !bookmarks.isEmpty || !history.isEmpty {
            if isFullPage {
                HStack(spacing: 10) {
                    if !bookmarks.isEmpty {
                        destructiveButton(title: "Clear All Bookmarks", icon: "trash") {
                            bookmarks.removeAll()
                            Persistence.saveBookmarks(bookmarks)
                        }
                    }
                    if !history.isEmpty {
                        destructiveButton(title: "Clear All History", icon: "trash") {
                            history.removeAll()
                            Persistence.saveHistory(history)
                        }
                    }
                }
                .padding(.top, 4)
            } else {
                Button(role: .destructive) {
                    bookmarks.removeAll()
                    history.removeAll()
                    Persistence.saveBookmarks(bookmarks)
                    Persistence.saveHistory(history)
                } label: {
                    Label("Delete Everything", systemImage: "trash.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if isFullPage {
            content()
                .padding(14)
                .background { fullPageCardSurface }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 1)
                )
        } else {
            content()
        }
    }

    private var fullPageCardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Group {
            if glassEnabled {
                shape.fill(.regularMaterial)
                    .searxlyGlass(.regular, in: shape)
            } else {
                shape.fill(AdaptiveChrome.fill(colorScheme, dark: 0.03, light: 0.025))
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.45)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AdaptiveChrome.fill(colorScheme, dark: 0.05), in: Capsule())
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                AdaptiveChrome.fill(colorScheme, dark: 0.03, light: 0.025),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }

    private func destructiveButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(minHeight: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var pageBackground: some View {
        ZStack {
            if isFullPage {
                AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled)
                    .ignoresSafeArea()

                if glassEnabled, colorScheme == .dark {
                    RadialGradient(
                        colors: [Color.white.opacity(0.04), Color.clear],
                        center: .top,
                        startRadius: 24,
                        endRadius: 420
                    )
                    .ignoresSafeArea()
                }
            } else if glassEnabled {
                Rectangle()
                    .fill(.regularMaterial)
                    .background {
                        Rectangle()
                            .fill(AdaptiveChrome.panelTint(colorScheme))
                    }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private func openItem(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        searchText = urlString
        loadInWebView(url)
        if isFullPage {
            onCloseFullPage?()
        } else {
            showingBookmarks = false
        }
    }
}
