//
//  WalletLineChart.swift
//  Searxly
//
//  Reusable monochrome line+area chart for price history and the portfolio graph. Brand rule: the line
//  is neutral gray, turning green when the series ends higher than it started and red when lower —
//  color carries meaning (direction), never decoration. Two variants:
//   • compact   — home portfolio sparkline (no axes, no interaction)
//   • full      — token detail (drag to scrub; reports the hovered point via `onScrub`)
//

import SwiftUI
import Charts

struct WalletLineChart: View {
    let points: [PricePoint]
    var compact: Bool = false
    /// Full variant only: fires with the hovered point while scrubbing, nil when the drag ends.
    var onScrub: ((PricePoint?) -> Void)? = nil

    @State private var selectedID: TimeInterval?

    /// Green when the window ends up, red when down, neutral when flat / insufficient data.
    private var tone: Color {
        guard points.count >= 2, let first = points.first?.v, let last = points.last?.v else {
            return WalletTheme.textTertiary
        }
        if last > first { return WalletTheme.positive }
        if last < first { return WalletTheme.negative }
        return WalletTheme.textTertiary
    }

    private var yDomain: ClosedRange<Double> {
        let vs = points.map(\.v)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        if lo == hi { return (lo - abs(lo) * 0.01 - 0.0001)...(hi + abs(hi) * 0.01 + 0.0001) }
        let pad = (hi - lo) * 0.08
        return (lo - pad)...(hi + pad)
    }

    private var selectedPoint: PricePoint? {
        guard let id = selectedID else { return nil }
        return points.first { $0.id == id }
    }

    /// Tone for a value relative to the window's start — green if up to here, red if down.
    private func tone(forValue v: Double) -> Color {
        guard let first = points.first?.v else { return WalletTheme.textTertiary }
        if v > first { return WalletTheme.positive }
        if v < first { return WalletTheme.negative }
        return WalletTheme.textTertiary
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Value", p.v))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(compact ? tone.opacity(0.85) : tone)
                    .lineStyle(StrokeStyle(lineWidth: compact ? 1.3 : 2.5, lineCap: .round, lineJoin: .round))
                AreaMark(x: .value("Time", p.t), y: .value("Value", p.v))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tone.opacity(compact ? 0.13 : 0.22), tone.opacity(0.03), tone.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            if let sel = selectedPoint, !compact {
                RuleMark(x: .value("Time", sel.t))
                    .foregroundStyle(WalletTheme.hairlineStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Time", sel.t), y: .value("Value", sel.v))
                    .foregroundStyle(tone(forValue: sel.v))   // green if up from start, red if down
                    .symbolSize(54)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.background(Color.clear) }
        .chartOverlay { proxy in
            if !compact {
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        // Hover is the natural scrub on macOS; the drag covers trackpad press-drags too.
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): scrub(toX: location.x, proxy: proxy, geo: geo)
                            case .ended: selectedID = nil; onScrub?(nil)
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { scrub(toX: $0.location.x, proxy: proxy, geo: geo) }
                                .onEnded { _ in selectedID = nil; onScrub?(nil) }
                        )
                }
            }
        }
    }

    /// Maps an x position (in the overlay's space) to the nearest data point and selects it.
    private func scrub(toX locationX: CGFloat, proxy: ChartProxy, geo: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let x = locationX - geo[anchor].minX
        guard let date = proxy.value(atX: x, as: Date.self),
              let nearest = nearestPoint(to: date) else { return }
        selectedID = nearest.id
        onScrub?(nearest)
    }

    private func nearestPoint(to date: Date) -> PricePoint? {
        points.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
    }
}
