//
//  LibraryView.swift
//  SearxlyiOS
//
//  Bookmarks · Reading List · History, presented as a sheet from the bottom bar's book button.
//  Search filters the active tab; History is grouped into date sections (Today, Yesterday, Previous
//  7 / 30 Days, Older) like Safari. Every row carries a context menu (open, open in new tab, copy,
//  share, bookmark/rename/delete); bookmarks can be dragged to reorder and renamed in place.
//

import SwiftUI

struct LibraryView: View {
    /// Opens a chosen URL in the active tab.
    let onOpen: (URL) -> Void
    /// Opens a chosen URL in a brand-new tab (Library stays put isn't needed — the sheet dismisses).
    var onOpenInNewTab: ((URL) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore.shared
    @State private var reading = ReadingListStore.shared
    @State private var tab: Tab
    @State private var showSettings = false
    @State private var query = ""
    @State private var renaming: Bookmark?
    @State private var renameText = ""

    enum Tab: Hashable { case bookmarks, reading, history }

    init(initialTab: Tab = .bookmarks,
         onOpen: @escaping (URL) -> Void,
         onOpenInNewTab: ((URL) -> Void)? = nil) {
        self.onOpen = onOpen
        self.onOpenInNewTab = onOpenInNewTab
        var start = initialTab
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SEARXLY_DEMO_LIBTAB"] {
        case "history": start = .history
        case "reading": start = .reading
        case "bookmarks": start = .bookmarks
        default:
            if ProcessInfo.processInfo.environment["SEARXLY_DEMO_PANEL"] == "reading" { start = .reading }
        }
        #endif
        _tab = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L("Bookmarks")).tag(Tab.bookmarks)
                    Text(readingLabel).tag(Tab.reading)
                    Text(L("History")).tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                List {
                    switch tab {
                    case .bookmarks: bookmarksSection
                    case .reading:   readingSection
                    case .history:   historySection
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: searchPrompt)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .tint(Brand.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }.tint(Brand.text)
                }
                // Reorder/multi-delete makes sense only for the (unfiltered) bookmarks list.
                if tab == .bookmarks && !store.bookmarks.isEmpty && query.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton().tint(Brand.text) }
                }
                if tab == .history && !store.history.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button(L("Clear History"), role: .destructive) { store.clearHistory() }
                    }
                }
                if tab == .reading && reading.items.contains(where: { !$0.isRead }) {
                    ToolbarItem(placement: .bottomBar) {
                        Button(L("Mark All Read")) {
                            for item in reading.items where !item.isRead { reading.setRead(item.id, true) }
                        }
                        .tint(Brand.text)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert(L("Rename Bookmark"), isPresented: renamePresented) {
                TextField(L("Title"), text: $renameText)
                Button(L("Cancel"), role: .cancel) { renaming = nil }
                Button(L("Save")) {
                    if let bm = renaming { store.renameBookmark(url: bm.url, title: renameText) }
                    renaming = nil
                }
            }
            .tint(Brand.text)
        }
    }

    // MARK: - Titles / labels

    private var navTitle: String {
        switch tab {
        case .bookmarks: return L("Bookmarks")
        case .reading:   return L("Reading List")
        case .history:   return L("History")
        }
    }

    private var readingLabel: String {
        let unread = reading.unreadCount
        return unread > 0 ? "\(L("Reading")) (\(unread))" : L("Reading")
    }

    private var searchPrompt: String {
        switch tab {
        case .bookmarks: return L("Search Bookmarks")
        case .reading:   return L("Search Reading List")
        case .history:   return L("Search History")
        }
    }

    // MARK: - Bookmarks

    @ViewBuilder private var bookmarksSection: some View {
        if store.bookmarks.isEmpty {
            emptyState(L("No bookmarks yet"), L("Open a page, tap ⋯, then Add Bookmark."))
        } else if query.isEmpty {
            ForEach(store.bookmarks) { bm in
                entryRow(title: bm.title, url: bm.url, isBookmark: true)
            }
            .onMove { store.moveBookmarks(from: $0, to: $1) }
            .onDelete { store.removeBookmarks(at: $0) }
        } else {
            let results = filteredBookmarks
            if results.isEmpty {
                noResults
            } else {
                ForEach(results) { bm in
                    entryRow(title: bm.title, url: bm.url, isBookmark: true)
                }
            }
        }
    }

    private var filteredBookmarks: [Bookmark] {
        store.bookmarks.filter { matches($0.title, $0.url) }
    }

    // MARK: - Reading list

    @ViewBuilder private var readingSection: some View {
        if reading.items.isEmpty {
            emptyState(L("Nothing saved to read"), L("Tap ⋯ then Add to Reading List, or long-press a result."))
        } else {
            let items = query.isEmpty ? reading.items : reading.items.filter { matches($0.title, $0.url) }
            if items.isEmpty {
                noResults
            } else {
                ForEach(items) { item in
                    Button {
                        reading.setRead(item.id, true)
                        open(item.url)
                    } label: {
                        readingRow(item)
                    }
                    .listRowBackground(Brand.bg)
                    .listRowSeparatorTint(Brand.hairline)
                    .contextMenu { rowMenu(url: item.url, title: item.title, isBookmark: false) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            reading.setRead(item.id, !item.isRead)
                        } label: {
                            Label(item.isRead ? L("Mark Unread") : L("Mark Read"),
                                  systemImage: item.isRead ? "circle" : "checkmark.circle")
                        }
                        .tint(Color(white: 0.35))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let idx = reading.items.firstIndex(where: { $0.id == item.id }) {
                                reading.remove(at: IndexSet(integer: idx))
                            }
                        } label: { Label(L("Delete"), systemImage: "trash") }
                    }
                }
            }
        }
    }

    private func readingRow(_ item: ReadingItem) -> some View {
        HStack(spacing: 12) {
            FaviconView(host: host(item.url))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.url : item.title)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(item.isRead ? Brand.textSecondary : Brand.text)
                    .lineLimit(1)
                Text(prettyURL(item.url))
                    .font(.caption)
                    .foregroundStyle(Brand.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !item.isRead {
                Circle().fill(Brand.text).frame(width: 8, height: 8)
                    .accessibilityLabel(L("Unread"))
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - History (date-grouped, Safari-style)

    @ViewBuilder private var historySection: some View {
        if store.history.isEmpty {
            emptyState(L("No history"), L("Pages you visit show up here."))
        } else {
            let groups = groupedHistory(query.isEmpty ? store.history
                                                     : store.history.filter { matches($0.title, $0.url) })
            if groups.isEmpty {
                noResults
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            entryRow(title: entry.title, url: entry.url, isBookmark: false,
                                     stamp: historyStamp(entry.visitedAt))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.removeHistory(id: entry.id)
                                    } label: { Label(L("Delete"), systemImage: "trash") }
                                }
                        }
                    } header: {
                        Text(group.title)
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
        }
    }

    private struct DatedGroup: Identifiable {
        let id: Int
        let title: String
        let entries: [HistoryEntry]
    }

    /// Buckets newest-first history into Safari's date sections; empty buckets are dropped.
    private func groupedHistory(_ entries: [HistoryEntry]) -> [DatedGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let last7 = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let last30 = cal.date(byAdding: .day, value: -30, to: today) ?? today

        var buckets: [[HistoryEntry]] = Array(repeating: [], count: 5)
        for e in entries {
            let d = e.visitedAt
            if d >= today { buckets[0].append(e) }
            else if d >= yesterday { buckets[1].append(e) }
            else if d >= last7 { buckets[2].append(e) }
            else if d >= last30 { buckets[3].append(e) }
            else { buckets[4].append(e) }
        }
        let titles = [L("Today"), L("Yesterday"), L("Previous 7 Days"), L("Previous 30 Days"), L("Older")]
        return (0..<5).compactMap { i in
            buckets[i].isEmpty ? nil : DatedGroup(id: i, title: titles[i], entries: buckets[i])
        }
    }

    /// Time-of-day for today/yesterday, a short date otherwise.
    private func historyStamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInYesterday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Shared row

    private func entryRow(title: String, url: String, isBookmark: Bool, stamp: String? = nil) -> some View {
        Button { open(url) } label: {
            HStack(spacing: 12) {
                FaviconView(host: host(url))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? prettyURL(url) : title)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                    Text(prettyURL(url))
                        .font(.caption)
                        .foregroundStyle(Brand.textTertiary)
                        .lineLimit(1)
                }
                if let stamp {
                    Spacer(minLength: 6)
                    Text(stamp)
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(Brand.textTertiary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Brand.bg)
        .listRowSeparatorTint(Brand.hairline)
        .contextMenu { rowMenu(url: url, title: title, isBookmark: isBookmark) }
    }

    /// Long-press actions shared by every row.
    @ViewBuilder private func rowMenu(url: String, title: String, isBookmark: Bool) -> some View {
        if let u = URL(string: url) {
            Button { open(url) } label: { Label(L("Open"), systemImage: "arrow.up.forward") }
            if onOpenInNewTab != nil {
                Button {
                    onOpenInNewTab?(u); dismiss()
                } label: { Label(L("Open in New Tab"), systemImage: "plus.square.on.square") }
            }
            Button { UIPasteboard.general.string = url } label: {
                Label(L("Copy Link"), systemImage: "doc.on.doc")
            }
            ShareLink(item: u) { Label(L("Share…"), systemImage: "square.and.arrow.up") }
            Divider()
            if isBookmark {
                Button {
                    renameText = title
                    renaming = store.bookmarks.first { $0.url == url } ?? Bookmark(url: url, title: title, addedAt: .now)
                } label: { Label(L("Rename"), systemImage: "pencil") }
                Button(role: .destructive) { store.removeBookmark(url: url) } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
            } else if store.isBookmarked(url) {
                Button { store.removeBookmark(url: url) } label: {
                    Label(L("Remove Bookmark"), systemImage: "bookmark.slash")
                }
            } else {
                Button { store.toggleBookmark(url: url, title: title) } label: {
                    Label(L("Add Bookmark"), systemImage: "bookmark")
                }
            }
        }
    }

    // MARK: - Helpers

    private func open(_ url: String) {
        if let u = URL(string: url) { onOpen(u); dismiss() }
    }

    private func matches(_ title: String, _ url: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || url.localizedCaseInsensitiveContains(query)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }

    /// A tidy address for the subtitle: host + path, no scheme or "www.".
    private func prettyURL(_ url: String) -> String {
        guard let u = URL(string: url), let h = u.host else { return url }
        let host = h.replacingOccurrences(of: "www.", with: "")
        let path = u.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var noResults: some View {
        emptyState(L("No results"), L("Nothing here matches “\(query)”."))
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(Brand.textSecondary)
            Text(subtitle).font(.caption).foregroundStyle(Brand.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
