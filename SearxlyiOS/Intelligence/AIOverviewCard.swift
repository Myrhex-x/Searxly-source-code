//
//  AIOverviewCard.swift
//  SearxlyiOS
//
//  The AI Overview at the top of web results, on a Liquid Glass card: streams a grounded
//  on-device answer (guided generation — no fragile text parsing), styles [n] citations as
//  quiet superscripts, then shows favicon source chips (tap → open that result) and follow-up
//  searches. Question-like queries generate automatically; others get a one-tap Generate row.
//

import SwiftUI

struct AIOverviewCard: View {
    let model: BrowserModel

    private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    init(model: BrowserModel) {
        self.model = model
    }

    private enum Phase: Equatable {
        case idle, streaming, done, failed
    }

    @State private var phase: Phase = .idle
    @State private var answer = ""
    @State private var followUpQueries: [String] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        let scale = appearance.textScale
        Group {
            if phase == .idle {
                // Compact one-row invitation (non-question queries).
                Button { generate() } label: {
                    HStack(spacing: 8) {
                        sparklesBadge
                        Text(L("AI Overview"))
                            .font(.system(size: 14 * scale, weight: .semibold))
                            .foregroundStyle(Brand.text)
                        Spacer()
                        Text(L("Generate"))
                            .font(.system(size: 12.5 * scale, weight: .medium))
                            .foregroundStyle(Brand.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        sparklesBadge
                        Text(L("AI Overview"))
                            .font(.system(size: 14 * scale, weight: .semibold))
                            .foregroundStyle(Brand.text)
                        if phase == .streaming {
                            ProgressView().controlSize(.mini).tint(Brand.textTertiary)
                        }
                        Spacer()
                    }

                    if phase == .failed {
                        Text(L("The overview couldn't be generated."))
                            .font(.system(size: 13 * scale))
                            .foregroundStyle(Brand.textTertiary)
                    } else if !answer.isEmpty {
                        Text(styledAnswer(answer, scale: scale))
                            .foregroundStyle(Brand.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if phase == .done {
                        if !followUpQueries.isEmpty {
                            followUps
                        }
                        sources
                        if !answer.isEmpty {
                            Text(L("Generated on-device from these results — may contain mistakes."))
                                .font(.system(size: 10.5 * scale))
                                .foregroundStyle(Brand.textTertiary)
                        }
                    }
                }
                .padding(15)
            }
        }
        // ONE Liquid Glass surface for every phase (idle row grows into the full card).
        .glassEffect(.regular.tint(glassTint), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.smooth(duration: 0.25), value: phase)
        .onAppear { bootstrap() }
        .onDisappear { task?.cancel() }
        .accessibilityLabel("AI overview of the search results")
    }

    private var glassTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.03)
    }

    private var sparklesBadge: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.bg)
            .frame(width: 21, height: 21)
            .background(Brand.text, in: Circle())
    }

    /// Citations like [1] or [2][4] render as quiet raised markers instead of raw brackets.
    private func styledAnswer(_ text: String, scale: CGFloat) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = .system(size: 14.5 * scale)
        guard let regex = try? NSRegularExpression(pattern: #"\[\d{1,2}\]"#) else { return attr }
        let plain = String(text)
        for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            guard let r = Range(match.range, in: plain),
                  let ar = attr.range(of: String(plain[r]), options: .backwards) else { continue }
            attr[ar].font = .system(size: 10 * scale, weight: .bold)
            attr[ar].foregroundColor = Brand.textTertiary
            attr[ar].baselineOffset = 3.5
        }
        return attr
    }

    /// Favicon + host chips for the grounded sources.
    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(model.results.prefix(cachedSourceCount).enumerated()), id: \.element.id) { i, result in
                    Button { model.open(result) } label: {
                        HStack(spacing: 5) {
                            Text("\(i + 1)")
                                .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Brand.textTertiary)
                            FaviconView(host: result.displayHost, size: 15)
                            Text(result.displayHost)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(Brand.surfaceHi.opacity(0.75), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Follow-up searches as quiet hairline rows (no boxes-in-boxes).
    private var followUps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(followUpQueries.enumerated()), id: \.element) { i, q in
                if i > 0 {
                    Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 24)
                }
                Button { model.runSearch(q) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.textTertiary)
                        Text(q)
                            .font(.system(size: 13.5 * appearance.textScale))
                            .foregroundStyle(Brand.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.textTertiary)
                    }
                    .padding(.vertical, 8.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cachedSourceCount: Int {
        SearchIntelligence.cached(for: model.searchQuery)?.sourceCount ?? min(model.results.count, 8)
    }

    private func bootstrap() {
        if let hit = SearchIntelligence.cached(for: model.searchQuery) {
            answer = hit.text
            followUpQueries = hit.followUps
            phase = .done
        } else if SearchIntelligence.isQuestionLike(model.searchQuery) {
            generate()
        } else {
            phase = .idle
        }
    }

    /// Related searches: the instance's own suggestions when present, else the autocompleter
    /// (skipped in private tabs to keep their footprint minimal).
    private func loadFollowUps(for query: String) async -> [String] {
        let instanceSuggestions = model.searchSuggestions
            .filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        if !instanceSuggestions.isEmpty { return Array(instanceSuggestions.prefix(4)) }
        guard !model.isPrivate else { return [] }
        return Array(await SearchIntelligence.relatedSearches(for: query).prefix(4))
    }

    private func generate() {
        task?.cancel()
        answer = ""
        followUpQueries = []
        phase = .streaming
        let query = model.searchQuery
        let results = model.results
        let sourceCount = min(results.count, 8)
        task = Task {
            // Fetch related searches concurrently with the answer stream.
            async let related = loadFollowUps(for: query)
            do {
                for try await snapshot in SearchIntelligence.overview(query: query, results: results) {
                    guard !Task.isCancelled else { return }
                    answer = snapshot
                }
                let ups = await related
                guard !Task.isCancelled else { return }
                followUpQueries = ups
                _ = SearchIntelligence.store(answer: answer, followUps: ups, query: query, sourceCount: sourceCount)
                phase = .done
            } catch {
                if !Task.isCancelled {
                    // Even if the answer failed, show related searches so the block stays useful.
                    let ups = await related
                    followUpQueries = ups
                    phase = answer.isEmpty && ups.isEmpty ? .failed : .done
                }
            }
        }
    }
}
