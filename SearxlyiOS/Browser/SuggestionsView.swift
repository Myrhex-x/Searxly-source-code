//
//  SuggestionsView.swift
//  SearxlyiOS
//
//  Address-bar suggestions shown while typing: a "Search …" / "Go to …" action plus matching local
//  bookmarks & history. Fully private — nothing is sent anywhere as you type. Rendered as an overlay
//  ABOVE the bottom bar (never inside it), so it can't disturb the text field's focus.
//

import SwiftUI
import UIKit

struct SuggestionsView: View {
    /// How the panel presents: `.compact` is the floating card above the bar (typing, web pages);
    /// `.expanded` is the home page's full browse panel — top-sites grid + recents, scrollable.
    enum PanelStyle { case compact, expanded }

    let query: String
    /// Online autocomplete is allowed only when the user opted in AND the tab isn't private.
    var allowRemote: Bool = true
    var style: PanelStyle = .compact
    /// Private tabs hide the personal sections (Top Sites, Recent Searches) — a private surface
    /// must not display normal-mode browsing. Paste and Go stays (it reads nothing until tapped).
    var isPrivate: Bool = false
    let onSearch: (String) -> Void
    let onOpen: (URL) -> Void

    @State private var store = LibraryStore.shared
    @State private var remote: [String] = []
    private var appearance = AppearanceSettings.shared

    init(query: String, allowRemote: Bool = true, style: PanelStyle = .compact,
         isPrivate: Bool = false,
         onSearch: @escaping (String) -> Void, onOpen: @escaping (URL) -> Void) {
        self.query = query
        self.allowRemote = allowRemote
        self.style = style
        self.isPrivate = isPrivate
        self.onSearch = onSearch
        self.onOpen = onOpen
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var directURL: URL? { BrowserModel.directURL(trimmed) }
    private var remoteEnabled: Bool { allowRemote && ShieldSettings.shared.onlineSuggestions }

    var body: some View {
        Group {
            if style == .expanded {
                ScrollView { panelContent }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                panelContent
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
        .padding(.vertical, 6)
        // Liquid Glass panel — matches the elevated bottom dock (same tint language, stronger
        // lift). The expanded browse panel backs itself near-opaque: it covers the whole home,
        // and the news feed ghosting through full-height glass read as clutter.
        .glassEffect(.regular.tint(Brand.bg.opacity(style == .expanded ? 0.88 : 0.48)),
                     in: .rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Brand.hairline.opacity(1.1), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.32), radius: 22, y: 10)
    }

    @ViewBuilder
    private var panelContent: some View {
        let matches = store.suggestions(for: trimmed)
        VStack(spacing: 0) {
            if trimmed.isEmpty {
                // Empty field: Safari's start-typing panel — Paste and Go, then quick-access Top Sites,
                // then recent searches.
                // `hasStrings` is a banner-free check (unlike reading the string), so the clipboard is
                // only actually read when the user taps — nothing is inspected as you open the field.
                if UIPasteboard.general.hasStrings {
                    row(icon: "doc.on.clipboard", title: L("Paste and Go"),
                        subtitle: L("Open or search your clipboard")) {
                        pasteAndGo()
                    }
                }
                let sites = isPrivate ? [] : quickAccessURLs
                if !sites.isEmpty {
                    if UIPasteboard.general.hasStrings {
                        Rectangle().fill(Brand.hairline).frame(height: 0.5)
                            .padding(.horizontal, 14).padding(.top, 6)
                    }
                    sectionHeader(L("Top Sites"), clear: nil)
                    if style == .expanded {
                        topSitesGrid(sites)
                    } else {
                        topSitesRow(sites)
                    }
                }
                if !isPrivate, !store.recentSearches.isEmpty {
                    if !sites.isEmpty {
                        Rectangle().fill(Brand.hairline).frame(height: 0.5)
                            .padding(.horizontal, 14).padding(.top, 6)
                    }
                    sectionHeader(L("Recent Searches")) { store.clearRecentSearches() }
                    ForEach(store.recentSearches.prefix(style == .expanded ? 10 : 6), id: \.self) { term in
                        Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 48)
                        row(icon: "clock.arrow.circlepath", title: term, subtitle: L("Search again")) { onSearch(term) }
                    }
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
    }

    // MARK: - Empty-state quick access (Top Sites)

    /// Most-visited hosts; falls back to bookmarks on a fresh install with no history yet.
    private var quickAccessURLs: [String] {
        let sites = store.topSites(limit: 8).map(\.url)
        return sites.isEmpty ? store.bookmarks.prefix(8).map(\.url) : sites
    }

    /// Reads the clipboard ONLY now (on tap, never on open): a URL opens directly, anything else searches.
    private func pasteAndGo() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        if let url = BrowserModel.directURL(raw) { onOpen(url) } else { onSearch(raw) }
    }

    private func sectionHeader(_ title: String, clear: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Brand.textTertiary)
            Spacer()
            if let clear {
                Button(L("Clear"), action: clear)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(Brand.textSecondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Horizontal favicon tiles — tap to open. Cache-only icons (these are already-visited sites).
    private func topSitesRow(_ urls: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(urls, id: \.self) { siteTile($0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    /// The expanded panel's grid — Safari's focused start page, 4 across.
    private func topSitesGrid(_ urls: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                  spacing: 16) {
            ForEach(urls, id: \.self) { siteTile($0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func siteTile(_ urlString: String) -> some View {
        let host = URL(string: urlString)?.host?.replacingOccurrences(of: "www.", with: "") ?? urlString
        return Button {
            if let u = URL(string: urlString) { onOpen(u) }
        } label: {
            VStack(spacing: 7) {
                FaviconView(host: host, size: 34)
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Brand.surfaceHi.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Brand.hairline, lineWidth: 0.5)
                    )
                Text(siteLabel(host: host))
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .frame(width: 56)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Top site") + ": \(host)")
    }

    /// A short, stable name for a site tile — the second-level domain label ("apple", "wikipedia").
    private func siteLabel(host: String) -> String {
        let labels = host.split(separator: ".")
        let main = labels.count >= 2 ? String(labels[labels.count - 2]) : (labels.first.map(String.init) ?? host)
        return main.prefix(1).uppercased() + main.dropFirst()
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
                    .scaledFont(size: 15)
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
