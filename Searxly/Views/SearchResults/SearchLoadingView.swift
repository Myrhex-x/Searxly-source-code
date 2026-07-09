//
//  SearchLoadingView.swift
//  Searxly
//
//  Shown while a native search is in flight. Over Tor a search legitimately takes several seconds, so a
//  static spinner reads as "stuck" — this gives an animated loading bar, a Tor-aware message that sets the
//  expectation, and a live elapsed-time counter so it's visibly progressing, not frozen.
//

import Combine
import SwiftUI

struct SearchLoadingView: View {
    /// True when this search rides Tor (Maximum, or base app in Maximum-Privacy + Tor) — drives the copy.
    let torRouted: Bool

    @State private var elapsed: Double = 0
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            IndeterminateBar()

            VStack(spacing: 7) {
                Text(torRouted ? "Searching privately over Tor" : "Searching")
                    .font(.headline)

                Text(torRouted
                     ? "Routing your query through the Tor network for anonymity. This normally takes a few seconds — worth the wait."
                     : "Fetching results from your local search engine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(format: "%.1fs", elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .onReceive(tick) { _ in elapsed += 0.1 }
    }
}

/// A slim, indeterminate loading bar — a highlight sweeps left→right across a faint track, forever, so it
/// signals "actively working" during an opaque wait (unlike a determinate bar, since a Tor request gives
/// no real progress to report).
struct IndeterminateBar: View {
    var tint: Color = .primary
    private let trackWidth: CGFloat = 240
    private let segmentWidth: CGFloat = 84
    @State private var offset: CGFloat = -84

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.12))
            .frame(width: trackWidth, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: segmentWidth, height: 4)
                    .offset(x: offset)
            }
            .clipShape(Capsule())
            .onAppear {
                offset = -segmentWidth
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false)) {
                    offset = trackWidth
                }
            }
            .accessibilityLabel("Searching")
    }
}
