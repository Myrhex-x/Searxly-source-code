//
//  AIOverviewCard.swift
//  SearxlyiOS
//
//  The AI Overview at the top of web results, on a Liquid Glass card: a grounded on-device answer
//  (from the top result snippets) with [n] citations styled as quiet superscripts, favicon source
//  chips (tap → open that result), and follow-up searches. Tap-only — the model runs on a Generate tap.
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
    @Environment(\.colorScheme) private var colorScheme

    init(availability: PageIntelligence.Availability) { self.availability = availability }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Brand.bg)
                .frame(width: 21, height: 21)
                .background(Brand.text, in: Circle())
            Text(message)
                .font(.system(size: 12.5 * appearance.textScale))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if availability == .downloading {
                ProgressView().controlSize(.mini).tint(Brand.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(.regular.tint(colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.03)),
                     in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 0.5))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
    @Environment(\.colorScheme) private var colorScheme

    init(model: BrowserModel) {
        self.model = model
    }

    /// All state is read from the stable per-tab model — the card owns none of it.
    private var ai: AIOverviewModel { model.aiOverview }

    var body: some View {
        let scale = appearance.textScale
        Group {
            if ai.phase == .idle {
                Button { runGenerate() } label: {
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
                            .scaledFont(size: 10, weight: .semibold)
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
                        if ai.phase == .streaming {
                            ProgressView().controlSize(.mini).tint(Brand.textTertiary)
                        }
                        Spacer()
                    }

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
                    } else if !ai.answer.isEmpty {
                        Text(styledAnswer(ai.answer, scale: scale))
                            .foregroundStyle(Brand.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if ai.phase == .done {
                        if !ai.followUps.isEmpty {
                            followUps
                        }
                        sources
                        if !ai.answer.isEmpty {
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
        .animation(.smooth(duration: 0.25), value: ai.phase)
        // State lives on the model; here we only point it at the current query. NO onDisappear cancel —
        // the whole fix is that a recycled card must NOT tear down an in-flight generation.
        .onAppear {
            ai.sync(query: model.searchQuery)
            #if DEBUG
            if ProcessInfo.processInfo.environment["SEARXLY_DEMO_AUTOGEN"] == "1", ai.phase == .idle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { runGenerate() }
            }
            #endif
        }
        .onChange(of: model.searchQuery) { _, q in ai.sync(query: q) }
        .accessibilityLabel("AI overview of the search results")
    }

    private func runGenerate() {
        ai.generate(results: model.results, suggestions: model.searchSuggestions, isPrivate: model.isPrivate)
    }

    private var glassTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.03)
    }

    private var sparklesBadge: some View {
        Image(systemName: "sparkles")
            .scaledFont(size: 11, weight: .semibold)
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
        let count = ai.sourceCount > 0 ? ai.sourceCount : min(model.results.count, 8)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(model.results.prefix(count).enumerated()), id: \.element.id) { i, result in
                    Button { model.open(result) } label: {
                        HStack(spacing: 5) {
                            Text("\(i + 1)")
                                .scaledFont(size: 9.5, weight: .bold).monospacedDigit()
                                .foregroundStyle(Brand.textTertiary)
                            FaviconView(host: result.displayHost, size: 15)
                            Text(result.displayHost)
                                .scaledFont(size: 11.5, weight: .medium)
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
                            .font(.system(size: 13.5 * appearance.textScale))
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
            }
        }
    }
}
