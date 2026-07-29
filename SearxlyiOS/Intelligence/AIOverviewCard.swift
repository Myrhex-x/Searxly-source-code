//
//  AIOverviewCard.swift
//  SearxlyiOS
//
//  The AI Overview at the top of web results, on a Liquid Glass card: a grounded on-device answer
//  (from the top result snippets) with [n] citations styled as quiet superscripts — tappable, each
//  opens its source — favicon source chips (tap → open that result), and follow-up searches.
//  Question-like queries generate automatically (the behavior Settings promises); everything else
//  keeps a tap-to-Generate affordance so navigational searches never burn the model.
//
//  The card is a THIN view: all generation state lives on `model.aiOverview` (see AIOverviewModel), so
//  it survives the results List recycling this row mid-generation.
//

import SwiftUI

/// Shown in the overview's slot when AI Overview is ON but the on-device model isn't ready yet — so the
/// SERP explains the absence (Apple Intelligence off, or its model still downloading) instead of showing
/// nothing at all. Never shown on ineligible hardware. Also nudges the download along while visible.
struct AIOverviewStatusRow: View {
    let availability: PageIntelligence.Availability
    private var appearance = AppearanceSettings.shared
    private var locale = AppLocale.shared

    init(availability: PageIntelligence.Availability) { self.availability = availability }

    var body: some View {
        let _ = locale.languageCode
        HStack(spacing: 9) {
            AppleIntelligenceBadge(iconSize: 11, diameter: 21)
            Text(message)
                .font(.system(size: 12 * appearance.textScale))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if availability == .downloading {
                ProgressView().controlSize(.mini).tint(Brand.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .searxlyGlassCard(cornerRadius: 16)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .onAppear { PageIntelligence.requestModelIfNeeded() }
        .accessibilityLabel(message)
    }

    private var message: String {
        switch availability {
        case .downloading:
            return L("Apple Intelligence is preparing its on-device model — the AI Overview appears once it's ready.")
        case .notEnabled:
            return L("Turn on Apple Intelligence in iOS Settings to see an AI Overview here.")
        default:
            return ""
        }
    }
}

struct AIOverviewCard: View {
    let model: BrowserModel

    private var appearance = AppearanceSettings.shared
    private var locale = AppLocale.shared

    init(model: BrowserModel) {
        self.model = model
    }

    /// All state is read from the stable per-tab model — the card owns none of it.
    private var ai: AIOverviewModel { model.aiOverview }

    /// "Ask more" — a multi-turn chat grounded on the SAME top results (no new egress).
    @State private var showAskMore = false

    var body: some View {
        let _ = locale.languageCode
        let scale = appearance.textScale
        Group {
            if ai.phase == .idle {
                Button { runGenerate() } label: {
                    HStack(spacing: 8) {
                        sparklesBadge
                        Text(L("AI Overview"))
                            .font(.system(size: 13 * scale, weight: .semibold))
                            .foregroundStyle(Brand.text)
                        Spacer()
                        Text(L("Generate"))
                            .font(.system(size: 12 * scale, weight: .medium))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Generate AI overview of the search results"))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        sparklesBadge
                        Text(L("AI Overview"))
                            .font(.system(size: 13 * scale, weight: .semibold))
                            .foregroundStyle(Brand.text)
                        if ai.phase == .streaming {
                            ProgressView().controlSize(.mini).tint(Brand.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ai.phase == .streaming ? L("AI Overview") + " — " + L("generating") : L("AI Overview"))

                    if ai.phase == .failed {
                        Button { runGenerate() } label: {
                            HStack(spacing: 6) {
                                Text(ai.failureMessage.isEmpty ? L("The overview couldn't be generated.") : ai.failureMessage)
                                    .font(.system(size: 13 * scale))
                                    .foregroundStyle(Brand.textSecondary)
                                Image(systemName: "arrow.clockwise")
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(Brand.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L("Tries the overview again"))
                    } else if !ai.answer.isEmpty {
                        Text(styledAnswer(ai.answer, scale: scale))
                            .foregroundStyle(Brand.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == "searxly-cite",
                                      let n = Int(url.host ?? ""), n >= 1, n <= model.results.count
                                else { return .discarded }
                                model.open(model.results[n - 1])
                                return .handled
                            })
                    } else if ai.phase == .streaming {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(Brand.surface).frame(height: 10)
                            RoundedRectangle(cornerRadius: 3).fill(Brand.surface).frame(width: 220, height: 10)
                            RoundedRectangle(cornerRadius: 3).fill(Brand.surface).frame(width: 160, height: 10)
                        }
                        .redacted(reason: .placeholder)
                        .opacity(0.7)
                    }

                    if ai.phase == .done {
                        if !ai.answer.isEmpty { askMoreChip(scale: scale) }
                        if !ai.followUps.isEmpty { followUps }
                        sources
                        if !ai.answer.isEmpty {
                            Text(L("Generated on-device from these results — may contain mistakes."))
                                .font(.system(size: 10.5 * scale))
                                .foregroundStyle(Brand.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .searxlyGlassCard(cornerRadius: 16)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .animation(.smooth(duration: 0.25), value: ai.phase)
        // State lives on the model; here we only point it at the current query. NO onDisappear cancel —
        // the whole fix is that a recycled card must NOT tear down an in-flight generation.
        .onAppear {
            ai.sync(query: model.searchQuery)
            autoGenerateIfWarranted()
            #if DEBUG
            if ProcessInfo.processInfo.environment["SEARXLY_DEMO_AUTOGEN"] == "1", ai.phase == .idle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { runGenerate() }
            }
            #endif
        }
        .onChange(of: model.searchQuery) { _, q in
            ai.sync(query: q)
            autoGenerateIfWarranted()
        }
    }

    private func runGenerate() {
        ai.generate(results: model.results, suggestions: model.searchSuggestions, isPrivate: model.isPrivate)
    }

    /// Question-like queries answer themselves — the tap-to-Generate step made the overview feel
    /// broken ("nothing happens by itself"), and Settings already describes this exact behavior.
    /// `.idle` guards recycled rows and failed runs from re-triggering in a loop.
    private func autoGenerateIfWarranted() {
        guard ai.phase == .idle, SearchIntelligence.isQuestionLike(model.searchQuery) else { return }
        runGenerate()
    }

    private var sparklesBadge: some View {
        AppleIntelligenceBadge(iconSize: 11, diameter: 21)
    }

    /// Opens a chat grounded on the same snippets the overview used — follow-up questions
    /// without burning a fresh search or leaving the SERP.
    private func askMoreChip(scale: CGFloat) -> some View {
        Button { showAskMore = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11 * scale, weight: .semibold))
                Text(L("Ask more"))
                    .font(.system(size: 12.5 * scale, weight: .semibold))
            }
            .foregroundStyle(Brand.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Brand.surfaceHi, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAskMore) {
            PageChatSheet(searchQuery: model.searchQuery, results: model.results)
        }
        .accessibilityHint(L("Chat about these search results, on-device"))
    }

    /// Citations like [1] or [2][4] render as quiet raised markers instead of raw brackets — and
    /// carry a searxly-cite:// link so tapping one opens its source (handled by the openURL action
    /// above). Ranges come from the match itself, so repeated markers all get styled.
    private func styledAnswer(_ text: String, scale: CGFloat) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = .system(size: 14 * scale)
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2})\]"#) else { return attr }
        let plain = String(text)
        for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let r = Range(match.range, in: plain),
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr) else { continue }
            let ar = lo..<hi
            attr[ar].font = .system(size: 10 * scale, weight: .bold)
            attr[ar].foregroundColor = Brand.textSecondary
            attr[ar].baselineOffset = 3.5
            if let nr = Range(match.range(at: 1), in: plain), let n = Int(plain[nr]) {
                attr[ar].link = URL(string: "searxly-cite://\(n)")
            }
        }
        return attr
    }

    /// Favicon + host chips for the grounded sources.
    private var sources: some View {
        let count = ai.sourceCount > 0 ? ai.sourceCount : min(model.results.count, SearchIntelligence.groundingCount)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(model.results.prefix(count).enumerated()), id: \.element.id) { i, result in
                    Button { model.open(result) } label: {
                        HStack(spacing: 5) {
                            Text("\(i + 1)")
                                .scaledFont(size: 10, weight: .bold).monospacedDigit()
                                .foregroundStyle(Brand.textTertiary)
                            FaviconView(host: result.displayHost, size: 15)
                            Text(result.displayHost)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(Brand.surfaceHi.opacity(0.75), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(L("Source")) \(i + 1): \(result.displayHost)")
                }
            }
        }
        .accessibilityLabel(L("Sources"))
    }

    /// Follow-up searches as quiet hairline rows (no boxes-in-boxes).
    private var followUps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ai.followUps.enumerated()), id: \.element) { i, q in
                if i > 0 {
                    Rectangle().fill(Brand.hairline).frame(height: 0.5).padding(.leading, 24)
                }
                Button { model.runSearch(q) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(Brand.textTertiary)
                        Text(q)
                            .font(.system(size: 13 * appearance.textScale))
                            .foregroundStyle(Brand.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .scaledFont(size: 10)
                            .foregroundStyle(Brand.textTertiary)
                    }
                    .padding(.vertical, 8.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(L("Search")): \(q)")
            }
        }
    }
}
