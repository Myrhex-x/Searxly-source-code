//
//  OnboardingFeatureSlide.swift
//  Searxly
//
//  A presentation-style scaffold for the feature steps. On a wide window it lays out as
//  a landing-page split — big copy on the left, a large live demo on the right — and
//  stacks vertically when narrow. Everything reveals in a staggered entrance.
//

import SwiftUI

struct OnboardingPill: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

struct OnboardingFeatureSlide<Demo: View, Extra: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var pills: [OnboardingPill] = []
    @ViewBuilder var demo: () -> Demo
    @ViewBuilder var extra: () -> Extra

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= OnboardingStyle.wideBreakpoint

            Group {
                if wide {
                    HStack(alignment: .center, spacing: 44) {
                        textColumn(alignment: .leading)
                            .frame(width: min(380, geo.size.width * 0.40), alignment: .leading)
                        demoColumn
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 26) {
                            textColumn(alignment: .center)
                            demoColumn
                        }
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { revealed = true }
    }

    private func textColumn(alignment: HorizontalAlignment) -> some View {
        let textAlign: TextAlignment = alignment == .leading ? .leading : .center
        let frameAlign: Alignment = alignment == .leading ? .leading : .center

        return VStack(alignment: alignment, spacing: 16) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(.tertiary)
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.02)

            Text(title)
                .font(.system(size: 33, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(textAlign)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.08)

            Text(subtitle)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(textAlign)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.14)

            if !pills.isEmpty {
                FlowPills(pills: pills, alignment: alignment)
                    .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.2)
            }

            extra()
                .onboardingVisualReveal(revealed, reduceMotion: reduceMotion, delay: 0.26)
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    private var demoColumn: some View {
        ZStack {
            // Soft aura behind the demo so it reads as the hero.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.07 : 0.05),
                            .clear
                        ],
                        center: .center, startRadius: 10, endRadius: 360
                    )
                )
                .blur(radius: 12)
                .scaleEffect(1.08)

            demo()
                .fixedSize(horizontal: false, vertical: true)   // hug content height — don't stretch to fill the column
                .frame(maxWidth: 560)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.96)
                .opacity(revealed || reduceMotion ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82).delay(0.12), value: revealed)
        }
        .frame(maxWidth: .infinity)
    }
}

extension OnboardingFeatureSlide where Extra == EmptyView {
    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        pills: [OnboardingPill] = [],
        @ViewBuilder demo: @escaping () -> Demo
    ) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, pills: pills, demo: demo) { EmptyView() }
    }
}

/// Pills that wrap to the next line based on the ACTUAL available width, so a longer pill never
/// spills past the (narrow) text column or squashes its neighbours.
private struct FlowPills: View {
    let pills: [OnboardingPill]
    let alignment: HorizontalAlignment

    var body: some View {
        OnboardingFlowLayout(spacing: 8, lineSpacing: 8, alignment: alignment) {
            ForEach(pills) { pill in
                OnboardingFactPill(icon: pill.icon, text: pill.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }
}

/// A minimal wrapping flow layout: lays children left→right, wrapping to a new line when the next
/// child would overflow the proposed width. Wraps by real measured width, so pills of any length
/// stay inside their column.
struct OnboardingFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .center:   x = bounds.minX + (bounds.width - row.width) / 2
            case .trailing: x = bounds.maxX - row.width
            default:        x = bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if current.indices.isEmpty {
                current = Row(indices: [index], width: size.width, height: size.height)
            } else if current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.width += spacing + size.width
                current.indices.append(index)
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
