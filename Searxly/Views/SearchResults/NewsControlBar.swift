//
//  NewsControlBar.swift
//  Searxly
//
//  Recency-first controls for the news tab: a time-range filter (wired to SearXNG `time_range`),
//  a Top/Latest sort toggle, and a refresh with a live "Updated Xm ago" readout. News only.
//

import SwiftUI

struct NewsControlBar: View {
    @Environment(\.colorScheme) private var colorScheme

    /// nil = any time; "day" / "week" / "month" / "year" map to SearXNG's accepted `time_range` values.
    let selectedTimeRange: String?
    let sortByRecency: Bool
    let lastRefreshed: Date?
    let isRefreshing: Bool
    let glassEnabled: Bool

    let onSelectTimeRange: (String?) -> Void
    let onToggleSort: (Bool) -> Void
    let onRefresh: () -> Void

    private let ranges: [(label: String, value: String?)] = [
        ("Any time", nil),
        ("24 hours", "day"),
        ("Week", "week"),
        ("Month", "month"),
        ("Year", "year")
    ]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)

                ForEach(ranges, id: \.label) { range in
                    pill(
                        label: Localization.string("news_range_\(range.value ?? "any")", defaultValue: range.label),
                        isSelected: selectedTimeRange == range.value,
                        action: { onSelectTimeRange(range.value) }
                    )
                }
            }

            Spacer(minLength: 8)

            sortToggle

            Button(action: onRefresh) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                    if let lastRefreshed {
                        // Re-renders every ~30s so the minutes tick up on their own.
                        TimelineView(.periodic(from: lastRefreshed, by: 30)) { context in
                            Text(TimelineDrivenRelativeText.string(from: lastRefreshed, now: context.date))
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Localization.string("news_refresh", defaultValue: "Refresh news"))
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Solid panel canvas so the bar matches the floating sidebar's darkness (not a light frosted
        // material). The range pills inside carry their own subtle wash, so they still read against it.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AdaptiveChrome.panelCanvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12, light: 0.10), lineWidth: 0.75)
        )
        .shadow(color: AdaptiveChrome.shadow(colorScheme, darkOpacity: 0.22), radius: 5, x: 0, y: 1)
    }

    // MARK: - Pieces

    private func pill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .fixedSize()
                .serpGlassCapsule(isSelected: isSelected, glassEnabled: glassEnabled)
        }
        .buttonStyle(.plain)
    }

    private var sortToggle: some View {
        HStack(spacing: 0) {
            sortSegment(
                label: Localization.string("news_sort_top", defaultValue: "Top"),
                isSelected: !sortByRecency,
                action: { onToggleSort(false) }
            )
            sortSegment(
                label: Localization.string("news_sort_latest", defaultValue: "Latest"),
                isSelected: sortByRecency,
                action: { onToggleSort(true) }
            )
        }
        .background(
            Capsule().fill(AdaptiveChrome.fill(colorScheme, dark: 0.03))
        )
        .overlay(
            Capsule().strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    private func sortSegment(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    isSelected
                        ? AdaptiveChrome.fill(colorScheme, dark: glassEnabled ? 0.10 : 0.08)
                        : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

/// Small helper so the "Updated Xm ago" text recomputes on the TimelineView cadence.
private enum TimelineDrivenRelativeText {
    static func string(from date: Date, now: Date = Date()) -> String {
        let secs = max(0, now.timeIntervalSince(date))
        if secs < 60 { return Localization.string("news_updated_now", defaultValue: "Updated just now") }
        let mins = Int(secs / 60)
        if mins < 60 { return String(format: Localization.string("news_updated_min", defaultValue: "Updated %dm ago"), mins) }
        let hours = Int(secs / 3600)
        return String(format: Localization.string("news_updated_hr", defaultValue: "Updated %dh ago"), hours)
    }
}
