//
//  LibraryView.swift
//  SearxlyiOS
//
//  Bookmarks + History, presented as a sheet from the bottom bar's book button. Tap an entry to open
//  it; swipe to delete; clear all history. A gear opens Settings.
//

import SwiftUI

struct LibraryView: View {
    /// Opens a chosen URL in the active tab.
    let onOpen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore.shared
    @State private var tab: Tab = .bookmarks
    @State private var showSettings = false

    enum Tab: Hashable { case bookmarks, history }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Bookmarks").tag(Tab.bookmarks)
                    Text("History").tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                List {
                    switch tab {
                    case .bookmarks: bookmarksSection
                    case .history:   historySection
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(tab == .bookmarks ? "Bookmarks" : "History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .tint(Brand.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Brand.text)
                }
                if tab == .history && !store.history.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear History", role: .destructive) { store.clearHistory() }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .tint(Brand.text)
        }
    }

    @ViewBuilder private var bookmarksSection: some View {
        if store.bookmarks.isEmpty {
            emptyState("No bookmarks yet", "Open a page, tap ⋯, then Add Bookmark.")
        } else {
            ForEach(store.bookmarks) { bm in
                entryRow(title: bm.title, url: bm.url)
            }
            .onDelete { store.removeBookmarks(at: $0) }
        }
    }

    @ViewBuilder private var historySection: some View {
        if store.history.isEmpty {
            emptyState("No history", "Pages you visit show up here.")
        } else {
            ForEach(store.history) { entry in
                entryRow(title: entry.title, url: entry.url)
            }
            .onDelete { store.removeHistory(at: $0) }
        }
    }

    private func entryRow(title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { onOpen(u); dismiss() }
        } label: {
            HStack(spacing: 12) {
                FaviconView(host: URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? url : title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(Brand.textTertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Brand.bg)
        .listRowSeparatorTint(Brand.hairline)
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(Brand.textSecondary)
            Text(subtitle).font(.caption).foregroundStyle(Brand.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
