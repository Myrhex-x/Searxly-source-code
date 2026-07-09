//
//  SearxlyWidgets.swift
//  SearxlyWidgets — Home Screen widget extension
//  (Lock Screen accessory families are a small follow-on: add .accessoryRectangular with a compact
//   layout to `supportedFamilies` once you can preview them in Xcode.)
//
//  Two monochrome widgets, in the Searxly brand (black & white only):
//   • Privacy       — the lifetime "trackers blocked" count, read from the shared App Group
//                     container the app writes to (see SharedPrivacyStats). Tapping opens the app.
//   • Quick Actions — one-tap New Search / Private Tab / Reopen Last, each a searxly:// deep link
//                     the app already handles in BrowserView.handleDeepLink.
//
//  Self-contained: the ONLY app source this target needs is SharedPrivacyStats.swift — add it to
//  this target's membership (Xcode ▸ File Inspector ▸ Target Membership). Everything else is inline.
//  No network, no data collection; the count is a local mirror.
//

import WidgetKit
import SwiftUI

// MARK: - Privacy (trackers blocked)

private struct PrivacyEntry: TimelineEntry {
    let date: Date
    let blocked: Int
}

private struct PrivacyProvider: TimelineProvider {
    func placeholder(in context: Context) -> PrivacyEntry {
        PrivacyEntry(date: .now, blocked: 1_284)
    }
    func getSnapshot(in context: Context, completion: @escaping (PrivacyEntry) -> Void) {
        completion(PrivacyEntry(date: .now, blocked: SharedPrivacyStats.lifetimeBlocked))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PrivacyEntry>) -> Void) {
        let entry = PrivacyEntry(date: .now, blocked: SharedPrivacyStats.lifetimeBlocked)
        // Recompute in ~30 min; the app also nudges a reload each time it backgrounds.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private struct PrivacyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrivacyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold))
                Text("SEARXLY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
            }
            .foregroundStyle(.white.opacity(0.65))

            Spacer(minLength: 0)

            Text(entry.blocked.formatted(.number.notation(.compactName)))
                .font(.system(size: family == .systemSmall ? 34 : 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text("trackers blocked")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.black, for: .widget)
    }
}

struct SearxlyPrivacyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SearxlyPrivacyWidget", provider: PrivacyProvider()) { entry in
            PrivacyWidgetView(entry: entry)
        }
        .configurationDisplayName("Privacy")
        .description("Trackers Searxly has blocked for you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Quick Actions

private struct ActionsEntry: TimelineEntry { let date: Date }

private struct ActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActionsEntry { ActionsEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ActionsEntry) -> Void) {
        completion(ActionsEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ActionsEntry>) -> Void) {
        completion(Timeline(entries: [ActionsEntry(date: .now)], policy: .never))
    }
}

private struct QuickActionTile: View {
    let title: String
    let symbol: String
    let deepLink: String

    var body: some View {
        Link(destination: URL(string: deepLink)!) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ActionsWidgetView: View {
    var body: some View {
        HStack(spacing: 8) {
            QuickActionTile(title: "Search", symbol: "magnifyingglass", deepLink: "searxly://search")
            QuickActionTile(title: "Private", symbol: "hand.raised", deepLink: "searxly://private")
            QuickActionTile(title: "Reopen", symbol: "arrow.uturn.left", deepLink: "searxly://reopen")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.black, for: .widget)
    }
}

struct SearxlyActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SearxlyActionsWidget", provider: ActionsProvider()) { _ in
            ActionsWidgetView()
        }
        .configurationDisplayName("Quick Actions")
        .description("Start a private search, open a private tab, or reopen your last tab.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Bundle

@main
struct SearxlyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SearxlyPrivacyWidget()
        SearxlyActionsWidget()
    }
}
