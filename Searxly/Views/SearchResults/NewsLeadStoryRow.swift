//
//  NewsLeadStoryRow.swift
//  Searxly
//
//  Editorial hero for the freshest/top news story: a full-width banner image with the LIVE/BREAKING
//  badge overlaid and the source watermarked, then a large monochrome headline + snippet beneath.
//  Falls back to a headline-forward card when the story has no image.
//

import SwiftUI
import AppKit

struct NewsLeadStoryRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let result: SearXNGResult
    let glassEnabled: Bool
    let query: String?
    let isHighlighted: Bool
    let onOpenInNewTab: (() -> Void)?
    let onOpen: () -> Void

    @State private var isHovering = false

    private var thumbnailURL: URL? {
        for field in [result.thumbnail_src, result.thumbnail, result.img_src] {
            let t = field?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty, let u = URL(string: t) { return u }
        }
        return nil
    }

    private var headlineColor: Color {
        isHovering ? Color.primary.opacity(0.82) : Color.primary
    }

    var body: some View {
        Button(action: onOpen) {
            SERPResultRowChrome(
                glassEnabled: glassEnabled,
                isHighlighted: isHighlighted,
                isHovering: isHovering
            ) {
                VStack(alignment: .leading, spacing: 11) {
                    if thumbnailURL != nil {
                        heroImage
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        metaRow
                        Text(result.title)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(headlineColor)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .underline(isHovering, color: Color.primary.opacity(0.3))
                            .multilineTextAlignment(.leading)
                        snippetView
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.vertical, 12)
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
        .accessibilityLabel("Top story: \(result.title), \(result.newsSourceName)\(result.newsRelativeString.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens the news result in the browser")
    }

    // MARK: - Pieces

    private var heroImage: some View {
        CachedSearchThumbnail(
            // Request a hero-sized image (news thumbnails arrive tiny and pixelate when blown up), with
            // the original as a fallback candidate.
            candidates: result.newsThumbnailCandidates(width: 1024, height: 576),
            referer: result.url,
            aspectRatio: 16.0 / 9.0,
            fillFrameHeight: 200
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.10), lineWidth: 0.5)
        )
        .overlay(alignment: .topLeading) {
            NewsBadge(result: result)
                .padding(11)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 5) {
                FaviconView(pageURL: result.url, size: 13, cornerRadius: 3, loadRemote: true)
                Text(result.newsSourceName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(10)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            FaviconView(pageURL: result.url, size: 18, cornerRadius: 4, loadRemote: true)
            if thumbnailURL == nil {
                NewsBadge(result: result)
            }
            Text(result.newsSourceName)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let rel = result.newsRelativeString {
                Text("·").foregroundStyle(.quaternary)
                Text(rel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(result.newsTimeColor())
                    .lineLimit(1)
            }
        }
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
            .font(.system(size: 14.5))
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineSpacing(3)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}
