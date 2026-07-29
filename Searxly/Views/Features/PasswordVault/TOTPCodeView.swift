//
//  TOTPCodeView.swift
//  Searxly
//
//  Live two-factor code with a countdown ring, used in the vault list.
//
//  Driven by TimelineView rather than a Timer: SwiftUI suspends the schedule when the view is
//  off-screen, so a vault with many 2FA logins doesn't keep a fleet of timers alive, and the code
//  is recomputed from the supplied date instead of from mutated state.
//
//  Deliberately monochrome — the expiry ring conveys urgency through opacity, not colour, per the
//  brand rule that reserves colour for live status and pricing.
//

import SwiftUI

struct TOTPCodeView: View {
    let configuration: TOTPConfiguration
    var onCopy: (String) -> Void
    /// nil when autofill is switched off, which hides the fill button rather than offering an
    /// action that would silently do nothing.
    var onFill: ((String) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = TOTPGenerator.code(for: configuration, at: context.date)
            let remaining = TOTPGenerator.secondsRemaining(for: configuration, at: context.date)
            let progress = TOTPGenerator.progress(for: configuration, at: context.date)

            HStack(spacing: 10) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text(grouped(code))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .contentTransition(.numericText())
                    .animation(.default, value: code)

                countdownRing(progress: progress, remaining: remaining)

                Text("\(remaining)s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                if let code {
                    Button("Copy") { onCopy(code) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                    if let onFill {
                        Button("Fill") { onFill(code) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Fill this code on the current page")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AdaptiveChrome.fill(colorScheme, dark: 0.05, light: 0.04),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func countdownRing(progress: Double, remaining: Int) -> some View {
        ZStack {
            Circle()
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 1 - progress)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Fades as the window closes so an about-to-expire code reads as stale without
                // resorting to a warning colour.
                .opacity(remaining <= 5 ? 0.45 : 1)
        }
        .frame(width: 13, height: 13)
    }

    /// Splits the digits in half ("123456" → "123 456"), the grouping every authenticator app uses
    /// because it makes the code far easier to transcribe by eye.
    private func grouped(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "——————" }
        let midpoint = code.count / 2
        let splitIndex = code.index(code.startIndex, offsetBy: midpoint)
        return "\(code[..<splitIndex]) \(code[splitIndex...])"
    }
}
