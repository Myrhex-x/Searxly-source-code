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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var skeletonPulse = false
    /// Keep the SERP chrome subscribed to language changes (L() alone is easy to miss for Observation).
    private var locale = AppLocale.shared

    // Explicit init: private stored properties otherwise make the memberwise init private.
    init(model: BrowserModel) {
        self.model = model
    }

    /// News-tab lead: the freshest story with a real photo makes a magazine-style hero at the top.
    /// nil when no result has an upscalable photo (then the tab is just rows — never an empty hero).
    private var newsLead: SearXNGResult? {
        guard model.scope == .news else { return nil }
        return model.newsDisplayResults.first { $0.newsHasResizablePhoto }
    }

    /// Results shown as rows — the lead is lifted into the hero above, so it never appears twice.
    /// News reads the display order (Top/Latest applied); other scopes the ranked results as-is.
    private var rowResults: [SearXNGResult] {
        let base = model.scope == .news ? model.newsDisplayResults : model.results
        guard let lead = newsLead else { return base }
        return base.filter { $0.id != lead.id }
    }

    var body: some View {
        // Touch languageCode so App Language flips re-render scope labels / empty states.
        let _ = locale.languageCode
        VStack(spacing: 0) {
            scopeBar
            if model.scope == .news {
                NewsControlRow(model: model)
            }
            Rectangle().fill(Brand.hairline).frame(height: 0.5)

            ZStack {
                Brand.bg
                switch model.searchPhase {
                case .loading:          loading
                case .failed(let msg):  failed(msg)
                case .loaded, .idle:
                    if model.scope == .images {
                        ImageResultsView(model: model)
                    } else if model.scope == .videos {
                        VideoResultsView(model: model)
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
                    Button {
                        if !selected { Haptics.tick() }
                        model.setScope(scope)
                    } label: {
                        Text(scope.label)
                            .scaledFont(size: Brand.FontSize.footnote, weight: .semibold)
                            .foregroundStyle(selected ? Brand.bg : Brand.textSecondary)
                            .padding(.horizontal, Brand.Space.lg)
                            .padding(.vertical, 7)
                            // Only the active scope carries a filled pill — the rest stay quiet text, so the
                            // selector reads as one clear choice instead of four competing chips.
                            .background(selected ? Brand.text : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .animation(.easeOut(duration: 0.18), value: selected)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 9)
    }

    // MARK: - States

    /// Skeleton result rows instead of a bare spinner: the SERP keeps its shape while results land,
    /// which reads faster and calmer than a blank screen. Gently pulses (steady under Reduce Motion).
    private var loading: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in skeletonRow }
            }
            .padding(.top, 6)
            .opacity(skeletonPulse ? 0.55 : 1)
        }
        .scrollDisabled(true)
        .onAppear {
            guard !reduceMotion else { return }
            skeletonPulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { skeletonPulse = true }
        }
        .onDisappear { skeletonPulse = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Searching…"))
    }

    private var skeletonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Brand.surface)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(width: 120, height: 10)
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(height: 16)
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(width: 210, height: 16)
                RoundedRectangle(cornerRadius: 4).fill(Brand.surface).frame(height: 12).opacity(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

    /// A List (not a ScrollView) so rows get native trailing swipe actions.
    /// All-tab priority: **first website result first**, then AI / knowledge / news modules.
    private var webList: some View {
        let separatorLeading: CGFloat = model.scope == .news ? 16 : 58
        let isWeb = model.scope == .web
        let lead = isWeb ? rowResults.first : nil
        let rest = isWeb ? Array(rowResults.dropFirst()) : rowResults
        let showAI = isWeb && !model.results.isEmpty && ShieldSettings.shared.aiOverview
            && shouldShowAIOverviewSlot

        return List {
            if let newsHero = newsLead {
                HomeTopStoryHero(cluster: NewsCluster(lead: newsHero, others: []), onOpen: { model.open($0) })
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // 1) First hit above modules so navigational searches aren't buried.
            if let lead {
                resultRow(lead, index: 0, total: rowResults.count, separatorLeading: separatorLeading)
            }

            // 2) Modules
            if showAI {
                if PageIntelligence.isAvailable {
                    AIOverviewCard(model: model)
                        .id(model.searchQuery)
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

            if isWeb, !model.libraryMatches.isEmpty {
                LibraryMatchesModule(matches: model.libraryMatches) { url in model.load(url) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if isWeb, let card = knowledgeCard {
                KnowledgeCardView(card: card) { url in model.load(url) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if isWeb, !model.allTabNews.isEmpty {
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

            // 3) Remaining results
            ForEach(Array(rest.enumerated()), id: \.element.id) { offset, result in
                let index = (lead == nil ? 0 : 1) + offset
                resultRow(result, index: index, total: rowResults.count, separatorLeading: separatorLeading)
            }

            if model.canLoadMore || model.isLoadingMore {
                loadMoreFooter
                    .id("serp-load-more-\(model.results.count)-\(model.isLoadingMore)")
                    .onAppear { model.loadMore() }
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
        .task(id: "\(model.searchQuery)|\(SearchSettings.shared.resolvedWikipediaLanguage)") {
            knowledgeCard = nil
            guard ShieldSettings.shared.knowledgeCards, !model.isPrivate else { return }
            knowledgeCard = await KnowledgeCardService.card(
                for: model.searchQuery,
                language: SearchSettings.shared.resolvedWikipediaLanguage
            )
        }
    }

    /// AI only when question-like (auto) or already mid/done for this query — no idle Generate row
    /// on pure website lookups.
    private var shouldShowAIOverviewSlot: Bool {
        // Live/finished generation for THIS query, or a session-cached overview for it — never
        // stale state from another query (which would flash a slot that resets itself away).
        if model.aiOverview.isActive(query: model.searchQuery) { return true }
        if SearchIntelligence.cached(for: model.searchQuery) != nil { return true }
        return SearchIntelligence.isQuestionLike(model.searchQuery)
    }

    @ViewBuilder
    private func resultRow(
        _ result: SearXNGResult,
        index: Int,
        total: Int,
        separatorLeading: CGFloat
    ) -> some View {
        Button { model.open(result) } label: {
            if model.scope == .news {
                NewsRowContent(result: result)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            } else {
                WebResultRow(result: result,
                             query: model.searchQuery,
                             showsThumbnail: model.scope != .web,
                             isOfficial: model.isOfficialHost(result.displayHost))
            }
        }
        .buttonStyle(.plain)
        .contextMenu { ResultContextMenu(result: result, model: model) }
        .onAppear {
            if index >= total - 4 { model.loadMore() }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Brand.hairline)
        .alignmentGuide(.listRowSeparatorLeading) { _ in separatorLeading }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
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

    private var loadMoreFooter: some View {
        Group {
            if model.isLoadingMore {
                ProgressView()
                    .tint(Brand.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                // Invisible but tall enough to enter the viewport as the user nears the end.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Web result row

private struct WebResultRow: View {
    let result: SearXNGResult
    var query: String = ""
    /// Videos/News rows show the result's thumbnail on the right when it has one.
    var showsThumbnail = false
    /// The query entity's own site carries a quiet seal beside the host (offline entity DB).
    var isOfficial = false

    private var appearance = AppearanceSettings.shared

    init(result: SearXNGResult, query: String = "", showsThumbnail: Bool = false, isOfficial: Bool = false) {
        self.result = result
        self.query = query
        self.showsThumbnail = showsThumbnail
        self.isOfficial = isOfficial
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
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(Brand.textTertiary)
                        .lineLimit(1)
                    if isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(Brand.textSecondary)
                            .accessibilityLabel(L("Official site"))
                    }
                    if let engines = result.enginesDisplay {
                        Text("· \(engines)")
                            .font(.system(size: 12 * scale))
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
        // One VoiceOver element per result — title, host, snippet in a single utterance instead
        // of four separate swipe stops per row.
        .accessibilityElement(children: .combine)
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

// MARK: - News controls (time filter + Top/Latest)

/// Recency controls under the scope bar, News only: SearXNG time-range pills and a Top/Latest
/// sort. Sorting is a pure client-side re-order; the time range re-runs the search.
private struct NewsControlRow: View {
    let model: BrowserModel
    private var appearance = AppearanceSettings.shared
    private var locale = AppLocale.shared

    init(model: BrowserModel) { self.model = model }

    private var ranges: [(label: String, value: String?)] {
        [(L("Any time"), nil), (L("24 hours"), "day"), (L("Week"), "week"),
         (L("Month"), "month"), (L("Year"), "year")]
    }

    var body: some View {
        let _ = locale.languageCode
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sortToggle
                Rectangle().fill(Brand.hairline).frame(width: 0.5, height: 16)
                Image(systemName: "clock")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(Brand.textTertiary)
                ForEach(ranges, id: \.label) { range in
                    let selected = model.newsTimeRange == range.value
                    Button {
                        if !selected { Haptics.tick() }
                        model.setNewsTimeRange(range.value)
                    } label: {
                        Text(range.label)
                            .scaledFont(size: 12, weight: selected ? .semibold : .medium)
                            .foregroundStyle(selected ? Brand.text : Brand.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(selected ? Brand.surfaceHi : Color.clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Brand.hairline : Color.clear, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: model.newsSortByRecency)
    }

    private var sortToggle: some View {
        HStack(spacing: 0) {
            sortSegment(L("Top"), isSelected: !model.newsSortByRecency) { model.newsSortByRecency = false }
            sortSegment(L("Latest"), isSelected: model.newsSortByRecency) { model.newsSortByRecency = true }
        }
        .background(Capsule().fill(Brand.surface))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 0.5))
        .clipShape(Capsule())
    }

    private func sortSegment(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if !isSelected { Haptics.tick(); action() }
        } label: {
            Text(label)
                .scaledFont(size: 12, weight: isSelected ? .semibold : .medium)
                .foregroundStyle(isSelected ? Brand.bg : Brand.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(isSelected ? Brand.text : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - "From your library" module (All tab)

/// Bookmark/history pages matching the query — a compact, purely local module. Rows open the
/// saved page directly; the icon distinguishes bookmarks from visited pages.
private struct LibraryMatchesModule: View {
    let matches: [Suggestion]
    let onOpen: (URL) -> Void
    private var appearance = AppearanceSettings.shared

    init(matches: [Suggestion], onOpen: @escaping (URL) -> Void) {
        self.matches = matches
        self.onOpen = onOpen
    }

    var body: some View {
        let scale = appearance.textScale
        VStack(alignment: .leading, spacing: 0) {
            Text(L("From your library"))
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(Brand.textTertiary)
                .textCase(.uppercase)
                .kerning(0.6)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(matches) { match in
                Button {
                    if let url = URL(string: match.url) { onOpen(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: match.icon)
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(Brand.textSecondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.title.isEmpty ? match.url : match.title)
                                .font(.system(size: 14 * scale, weight: .medium))
                                .foregroundStyle(Brand.text)
                                .lineLimit(1)
                            Text(URL(string: match.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? match.url)
                                .font(.system(size: 11 * scale))
                                .foregroundStyle(Brand.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
        .searxlyGlassCard(cornerRadius: 16)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
