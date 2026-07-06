//
//  NewsRowParts.swift
//  Searxly
//
//  Shared pieces for the news SERP rows: the LIVE / BREAKING badge and the pulsing dot.
//  News-urgency accent is red (broadcast "live" language); LIVE and BREAKING are solid-red chyron chips,
//  LIVE with a pulsing dot. Green stays reserved for wallet/price meaning elsewhere in the app.
//

import SwiftUI

/// LIVE (fresh < 1h) or BREAKING (headline-flagged, not stale) badge. Renders nothing otherwise.
/// BREAKING takes precedence — it's the stronger editorial signal.
struct NewsBadge: View {
    let result: SearXNGResult
    var compact: Bool = false

    var body: some View {
        if result.isBreakingNews {
            chip(text: Localization.string("news_badge_breaking", defaultValue: "BREAKING"), dot: false)
        } else if result.newsFreshness == .live {
            chip(text: Localization.string("news_badge_live", defaultValue: "LIVE"), dot: true)
        }
    }

    private func chip(text: String, dot: Bool) -> some View {
        HStack(spacing: compact ? 3.5 : 4) {
            if dot { PulsingLiveDot(size: compact ? 4.5 : 5.5, color: .white) }
            Text(text)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 2.5)
        .background(SERPDesign.liveRed, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A gently pulsing dot for the LIVE badge. Honors Reduce Motion (falls back to a steady dot).
struct PulsingLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 6
    var color: Color = SERPDesign.liveRed

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(pulsing ? 1.0 : 0.62)
            .opacity(pulsing ? 1.0 : 0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityHidden(true)
    }
}

extension SearXNGResult {
    /// Timestamp tint: red while the story is live (< 1h) to reinforce the "now" feeling; muted once it
    /// ages, so red stays meaningful instead of decorative.
    func newsTimeColor() -> Color {
        newsFreshness == .live ? SERPDesign.liveRed : .secondary
    }
}
