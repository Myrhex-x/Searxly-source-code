//
//  FullCoverageDisclosure.swift
//  Searxly
//
//  The "Full coverage · N sources" affordance under a clustered news story: a row of stacked source
//  logos that expands to the full list of outlets covering the same story, each openable.
//

import SwiftUI
import AppKit

struct FullCoverageDisclosure: View {
    @Environment(\.colorScheme) private var colorScheme

    /// The additional sources (excludes the lead already shown above).
    let others: [SearXNGResult]
    /// Total sources including the lead (for the label).
    let totalSources: Int
    let glassEnabled: Bool
    let onOpen: (SearXNGResult) -> Void
    let onOpenInNewTab: (SearXNGResult) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    stackedLogos
                    Text(Localization.string("news_full_coverage_label", defaultValue: "Full coverage"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(String(format: Localization.string("news_n_sources_dot", defaultValue: "· %d sources"), totalSources))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Localization.string("news_full_coverage_hint", defaultValue: "Other outlets covering this story"))

            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(others.prefix(10))) { source in
                        sourceRow(source)
                    }
                }
            }
        }
    }

    /// Up to three overlapping source favicons, each ringed in the canvas color so they read as a stack.
    private var stackedLogos: some View {
        HStack(spacing: -6) {
            ForEach(Array(others.prefix(3))) { source in
                FaviconView(pageURL: source.url, size: 18, cornerRadius: 9, loadRemote: true)
                    .padding(1.5)
                    .background(Circle().fill(AdaptiveChrome.panelCanvas))
            }
        }
    }

    private func sourceRow(_ result: SearXNGResult) -> some View {
        Button {
            onOpen(result)
        } label: {
            HStack(spacing: 7) {
                FaviconView(pageURL: result.url, size: 15, cornerRadius: 3.5, loadRemote: true)
                Text(result.newsSourceName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let rel = result.newsRelativeString {
                    Text("·").foregroundStyle(.quaternary)
                    Text(rel)
                        .font(.system(size: 11.5, weight: result.newsFreshness == .live ? .semibold : .regular))
                        .foregroundStyle(result.newsTimeColor())
                        .lineLimit(1)
                }
                Text(result.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Localization.string("search_result_open")) { onOpen(result) }
            Button(Localization.string("search_result_open_new_tab")) { onOpenInNewTab(result) }
        }
    }
}
