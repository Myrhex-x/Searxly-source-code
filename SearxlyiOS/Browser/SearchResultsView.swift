//
//  SearchResultsView.swift
//  SearxlyiOS
//
//  Searxly's own SwiftUI SERP, rendered from the SearXNG JSON API in the monochrome macOS style.
//  A Web / Images scope switcher sits on top; web results are rich rows (host chip + meta + snippet)
//  with long-press actions and infinite scroll; images render as a grid. Pull to refresh.
//

import SwiftUI
import UIKit

struct SearchResultsView: View {
    let model: BrowserModel

    /// Wikipedia knowledge card for entity queries (web scope, non-private, setting-gated).
    @State private var knowledgeCard: KnowledgeCard?

    /// News-tab lead: the freshest story with a real photo makes a magazine-style hero at the top.
    /// nil when no result has an upscalable photo (then the tab is just rows — never an empty hero).
    private var newsLead: SearXNGResult? {
        guard model.scope == .news else { return nil }
        return model.results.first { $0.newsHasResizablePhoto }
    }

    /// Results shown as rows — the lead is lifted into the hero above, so it never appears twice.
    private var rowResults: [SearXNGResult] {
        guard let lead = newsLead else { return model.results }
        return model.results.filter { $0.id != lead.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            Rectangle().fill(Brand.hairline).frame(height: 0.5)

            ZStack {
                Brand.bg
                switch model.searchPhase {
                case .loading:          loading
                case .failed(let msg):  failed(msg)
                case .loaded, .idle:
                    if model.scope == .images {
                        ImageResultsView(model: model)
                    } else {
                        webList
                    }
                }
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        // Edge-swipe back (results → home), mirroring the web view's native back gesture.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.startLocation.x < 30,
                       value.translation.width > 70,
                       abs(value.translation.height) < 60 {
                        Haptics.tick()
                        model.goBack()
                    }
                }
        )
    }

    // MARK: - Scope switcher

    private var scopeBar: some View {
        // Horizontal scroll: four scopes (+ future ones) never squeeze on narrow phones.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { scope in
                    let selected = model.scope == scope
                    Button { model.setScope(scope) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: scope.icon).scaledFont(size: 11, weight: .semibold)
                            Text(scope.label).scaledFont(size: 13, weight: .semibold)
                        }
                        .foregroundStyle(selected ? Brand.bg : Brand.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selected ? Brand.text : Brand.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 9)
    }

    // MARK: - States

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Brand.text)
            Text(L("Searching…")).font(.footnote).foregroundStyle(Brand.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .scaledFont(size: 34, weight: .light)
                .foregroundStyle(Brand.textTertiary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.textSecondary)
                .padding(.horizontal, 40)
            Button { model.runSearch(model.searchQuery) } label: {
                Text(L("Try again"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Brand.surfaceHi, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Web results

    /// A List (not a ScrollView) so rows get native trailing swipe actions:
    /// swipe LEFT on a result → Open in New Tab (full swipe) or Copy Link.
    private var webList: some View {
        // Computed here on the main actor: the separator inset closure below is @Sendable and can't
        // read the MainActor-isolated `model.scope` itself, so we capture the resolved value.
        let separatorLeading: CGFloat = model.scope == .news ? 16 : 58
        return List {
            // On-device AI Overview — allowed even in private tabs (zero egress). When the model isn't
            // ready yet (downloading / Apple Intelligence off) a one-line status row explains WHY the
            // overview is missing, instead of the SERP silently omitting it.
            if model.scope == .web, !model.results.isEmpty, ShieldSettings.shared.aiOverview {
                if PageIntelligence.isAvailable {
                    AIOverviewCard(model: model)
                        .id(model.searchQuery)  // fresh card (and stream) per query
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if PageIntelligence.availability == .downloading
                            || PageIntelligence.availability == .notEnabled {
                    AIOverviewStatusRow(availability: PageIntelligence.availability)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if model.scope == .web, let card = knowledgeCard {
                KnowledgeCardView(card: card) { url in model.load(url) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Google-style "Top stories" module — fresh news for the query, inline in the All results.
            if model.scope == .web, !model.allTabNews.isEmpty {
                AllTabNewsModule(
                    news: model.allTabNews,
                    query: model.searchQuery,
                    onOpen: { model.open($0) },
                    onSeeAll: { model.setScope(.news) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // News tab: a magazine-style lead story above the rows.
            if let lead = newsLead {
                HomeTopStoryHero(cluster: NewsCluster(lead: lead, others: []), onOpen: { model.open($0) })
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(Array(rowResults.enumerated()), id: \.element.id) { index, result in
                Button { model.open(result) } label: {
                    if model.scope == .news {
                        NewsRowContent(result: result)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                    } else {
                        WebResultRow(result: result,
                                     query: model.searchQuery,
                                     showsThumbnail: model.scope != .web)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { ResultContextMenu(result: result, model: model) }
                .onAppear {
                    if index >= rowResults.count - 3 { model.loadMore() }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Brand.hairline)
                .alignmentGuide(.listRowSeparatorLeading) { _ in separatorLeading }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        // Full-swipe queues a background tab (stay on results); the menu foregrounds.
                        if let url = URL(string: result.url) { model.onOpenInNewTabBackground?(url) }
                        Haptics.tick()
                    } label: {
                        Label(L("New Tab"), systemImage: "plus.square.on.square")
                    }
                    .tint(Color(white: 0.25))
                    Button {
                        UIPasteboard.general.string = result.url
                    } label: {
                        Label(L("Copy"), systemImage: "doc.on.doc")
                    }
                    .tint(Color(white: 0.45))
                }
                // Leading swipe → bookmark / unbookmark this result.
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        LibraryStore.shared.toggleBookmark(url: result.url, title: result.title)
                        Haptics.tick()
                    } label: {
                        let saved = LibraryStore.shared.isBookmarked(result.url)
                        Label(saved ? L("Remove Bookmark") : L("Add Bookmark"),
                              systemImage: saved ? "bookmark.slash.fill" : "bookmark.fill")
                    }
                    .tint(Color(white: 0.35))
                }
            }

            if model.isLoadingMore {
                ProgressView()
                    .tint(Brand.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.bg)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.runSearch(model.searchQuery) }
        .task(id: model.searchQuery) {
            knowledgeCard = nil
            guard ShieldSettings.shared.knowledgeCards, !model.isPrivate else { return }
            knowledgeCard = await KnowledgeCardService.card(
                for: model.searchQuery,
                language: SearchSettings.shared.language
            )
        }
    }
}

// MARK: - Web result row

private struct WebResultRow: View {
    let result: SearXNGResult
    var query: String = ""
    /// Videos/News rows show the result's thumbnail on the right when it has one.
    var showsThumbnail = false

    private var appearance = AppearanceSettings.shared

    init(result: SearXNGResult, query: String = "", showsThumbnail: Bool = false) {
        self.result = result
        self.query = query
        self.showsThumbnail = showsThumbnail
    }

    /// Google-style emphasis: occurrences of the query's meaningful terms render semibold
    /// in the snippet, so the eye lands on why this result matched.
    private func emphasized(_ text: String, scale: CGFloat) -> AttributedString {
        var attr = AttributedString(text)
        for term in query.lowercased().split(separator: " ") where term.count > 2 {
            var searchFrom = attr.startIndex
            var hits = 0
            while hits < 4,
                  let r = attr[searchFrom...].range(of: String(term),
                                                    options: [.caseInsensitive, .diacriticInsensitive]) {
                attr[r].font = .system(size: 14 * scale, weight: .semibold)
                searchFrom = r.upperBound
                hits += 1
            }
        }
        return attr
    }

    var body: some View {
        let scale = appearance.textScale
        HStack(alignment: .top, spacing: 12) {
            // Real favicon: cached from visits, or fetched anonymously for result hosts
            // when "Site Icons in Results" is on (letter chip otherwise).
            FaviconView(host: result.displayHost, fetchIfMissing: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(result.displayHost)
                        .font(.system(size: 12.5 * scale))
                        .foregroundStyle(Brand.textTertiary)
                        .lineLimit(1)
                    if let engines = result.enginesDisplay {
                        Text("· \(engines)")
                            .font(.system(size: 11.5 * scale))
                            .foregroundStyle(Brand.textTertiary.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Text(result.title)
                    .font(.system(size: 18 * scale, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .lineLimit(2)

                if let content = result.content, !content.isEmpty {
                    Text(emphasized(content, scale: scale))
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(3)
                }

                if let date = result.formattedPublishedDate() {
                    Text(date)
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(Brand.textTertiary)
                }
            }

            if showsThumbnail, SearchMediaURLResolver.hasAnyThumbnailField(result) {
                Spacer(minLength: 8)
                RemoteThumbView(result: result, keepsPlaceholder: true)
                    .frame(width: 92, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared bits (used by the image grid too)

/// Private, network-free favicon stand-in: the host's initial in a monochrome chip. Used as the
/// fallback face of FaviconView for hosts we haven't visited (no third-party favicon service is
/// ever hit — that would leak every result's host).
struct HostChip: View {
    let host: String
    var size: CGFloat = 30
    private var letter: String { host.first.map { String($0).uppercased() } ?? "?" }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 7 / 30, style: .continuous)
            .fill(Brand.surfaceHi)
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.system(size: size * 14 / 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.textSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 7 / 30, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 0.5)
            )
    }
}

struct ResultContextMenu: View {
    let result: SearXNGResult
    let model: BrowserModel

    var body: some View {
        Button { model.open(result) } label: { Label(L("Open"), systemImage: "arrow.up.right.square") }
        if let url = URL(string: result.url) {
            Button { model.onOpenInNewTab?(url) } label: {
                Label(L("Open in New Tab"), systemImage: "plus.square.on.square")
            }
            Button { ReadingListStore.shared.add(url: result.url, title: result.title) } label: {
                Label(L("Add to Reading List"), systemImage: "eyeglasses")
            }
            Button { UIPasteboard.general.string = result.url } label: {
                Label(L("Copy Link"), systemImage: "doc.on.doc")
            }
            ShareLink(item: url) { Label(L("Share…"), systemImage: "square.and.arrow.up") }
        }
    }
}
