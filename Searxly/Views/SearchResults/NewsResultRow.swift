//
//  NewsResultRow.swift
//  Searxly
//
//  News-flavored result row — same Google-like hierarchy as web with date emphasis.
//

import SwiftUI
import AppKit

struct NewsResultRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let result: SearXNGResult
    let glassEnabled: Bool
    let query: String?
    let isHighlighted: Bool
    let onOpenInNewTab: (() -> Void)?
    let onOpen: () -> Void

    @State private var isHovering = false

    private var thumbnailURL: URL? {
        let fields = [result.thumbnail_src, result.thumbnail, result.img_src]
        for f in fields {
            let t = f?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty, let u = URL(string: t) { return u }
        }
        return nil
    }

    private var snippetView: some View {
        let inner: Text = {
            guard let snippet = result.newsCleanSnippet, !snippet.isEmpty else { return Text("") }
            guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
                return Text(snippet)
            }

            var attr = AttributedString(snippet)
            let lowerSnippet = snippet.lowercased()
            let lowerQ = q.lowercased()

            var searchRange = lowerSnippet.startIndex..<lowerSnippet.endIndex
            while let r = lowerSnippet.range(of: lowerQ, range: searchRange) {
                if let attrRange = Range(r, in: attr) {
                    attr[attrRange].foregroundColor = .primary
                    attr[attrRange].backgroundColor = SERPDesign.liveRed.opacity(0.16)
                }
                searchRange = r.upperBound..<lowerSnippet.endIndex
            }
            return Text(attr)
        }()

        return inner
            .font(.system(size: 14))
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineSpacing(3)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    var body: some View {
        Button(action: onOpen) {
            SERPResultRowChrome(
                glassEnabled: glassEnabled,
                isHighlighted: isHighlighted,
                isHovering: isHovering
            ) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Source + live/breaking badge + relative time
                        HStack(spacing: 8) {
                            FaviconView(pageURL: result.url, size: 18, cornerRadius: 4, loadRemote: true)

                            NewsBadge(result: result, compact: true)

                            HStack(spacing: 6) {
                                Text(result.newsSourceName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if let rel = result.newsRelativeString {
                                    Text("·")
                                        .foregroundStyle(.quaternary)
                                    Text(rel)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(result.newsTimeColor())
                                        .lineLimit(1)
                                }
                            }
                        }

                        Text(result.title)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isHovering ? Color.primary.opacity(0.82) : Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .underline(isHovering, color: Color.primary.opacity(0.3))

                        snippetView
                    }

                    if thumbnailURL != nil {
                        CachedSearchThumbnail(
                            candidates: result.newsThumbnailCandidates(width: 360, height: 252),
                            referer: result.url,
                            aspectRatio: 4.0 / 3.0,
                            useNaturalAspect: true
                        )
                        .frame(width: 120, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.5)
                        )
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .onHover { hovering in
                DispatchQueue.main.async { isHovering = hovering }
                if hovering { HoverLinkState.shared.enter(result.url) }
                else { HoverLinkState.shared.leave(result.url) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Localization.string("search_result_open")) { onOpen() }
            if let newTab = onOpenInNewTab {
                Button(Localization.string("search_result_open_new_tab")) { newTab() }
            }
            Button(Localization.string("search_result_copy_link")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.url, forType: .string)
            }
        }
        .accessibilityLabel("\(result.title), \(result.newsSourceName)\(result.newsRelativeString.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens the news result in the browser")
    }
}