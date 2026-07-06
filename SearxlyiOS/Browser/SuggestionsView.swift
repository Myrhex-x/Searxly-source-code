//
//  SuggestionsView.swift
//  SearxlyiOS
//
//  Address-bar suggestions shown while typing: a "Search …" / "Go to …" action plus matching local
//  bookmarks & history. Fully private — nothing is sent anywhere as you type. Rendered as an overlay
//  ABOVE the bottom bar (never inside it), so it can't disturb the text field's focus.
//

import SwiftUI

struct SuggestionsView: View {
    let query: String
    /// Online autocomplete is allowed only when the user opted in AND the tab isn't private.
    var allowRemote: Bool = true
    let onSearch: (String) -> Void
    let onOpen: (URL) -> Void

    @State private var store = LibraryStore.shared
    @State private var remote: [String] = []
    private var appearance = AppearanceSettings.shared

    init(query: String, allowRemote: Bool = true,
         onSearch: @escaping (String) -> Void, onOpen: @escaping (URL) -> Void) {
        self.query = query
        self.allowRemote = allowRemote
        self.onSearch = onSearch
        self.onOpen = onOpen
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var directURL: URL? { BrowserModel.directURL(trimmed) }
    private var remoteEnabled: Bool { allowRemote && ShieldSettings.shared.onlineSuggestions }

    var body: some View {
        let matches = store.suggestions(for: trimmed)
        VStack(spacing: 0) {
            if trimmed.isEmpty {
                // Empty field: recent searches (Safari's start-typing panel).
                HStack {
                    Text(L("Recent Searches"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.textTertiary)
                    Spacer()
                    Button(L("Clear")) { store.clearRecentSearches() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.textSecondary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

                ForEach(store.recentSearches.prefix(6), id: \.self) { term in
                    Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 48)
                    row(icon: "clock.arrow.circlepath", title: term, subtitle: L("Search again")) { onSearch(term) }
                }
            } else {
                // Primary action: open as a URL if it clearly is one, else search.
                if let url = directURL {
                    row(icon: "globe", title: trimmed, subtitle: L("Open site")) { onOpen(url) }
                } else {
                    row(icon: "magnifyingglass", title: trimmed, subtitle: L("Search Searxly")) { onSearch(trimmed) }
                }

                ForEach(matches) { s in
                    Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 48)
                    suggestionRow(s)
                }

                // Opt-in online completions from the configured SearXNG instance (never in private tabs).
                ForEach(remote.filter { $0.lowercased() != trimmed.lowercased() }.prefix(4), id: \.self) { term in
                    Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 48)
                    row(icon: "arrow.up.left", title: term, subtitle: L("Search Searxly")) { onSearch(term) }
                }
            }
        }
        .task(id: trimmed) {
            guard remoteEnabled, !trimmed.isEmpty, directURL == nil else {
                remote = []
                return
            }
            // Small debounce so half-typed queries never leave the device.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            remote = await Self.fetchCompletions(for: trimmed)
        }
        .padding(.vertical, 4)
        // Liquid Glass panel — the dimmed page shows through, like the bottom bar it hovers over.
        .glassEffect(.regular.tint(Brand.bg.opacity(0.4)), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    /// Bookmark/history match: real favicon when cached (these are visited sites, so it almost
    /// always is), with the monochrome initial chip as fallback.
    private func suggestionRow(_ s: Suggestion) -> some View {
        Button {
            if let u = URL(string: s.url) { onOpen(u) }
        } label: {
            HStack(spacing: 12) {
                FaviconView(host: URL(string: s.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? s.url, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title)
                        .font(.system(size: 15 * appearance.textScale, weight: .medium))
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                    Text(s.url)
                        .font(.system(size: 12 * appearance.textScale))
                        .foregroundStyle(Brand.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// SearXNG's OpenSearch-style endpoint: `/autocompleter?q=…` → `["query", ["s1", "s2", …]]`.
    private static func fetchCompletions(for query: String) async -> [String] {
        var comps = URLComponents(string: "\(SearchSettings.shared.base)/autocompleter")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any],
              parsed.count >= 2, let terms = parsed[1] as? [String] else { return [] }
        return terms
    }

    private func row(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15 * appearance.textScale, weight: .medium))
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12 * appearance.textScale))
                        .foregroundStyle(Brand.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
