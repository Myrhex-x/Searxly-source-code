//
//  WebResultRow.swift
//  Searxly
//
//  Google-like web/general search result row.
//

import SwiftUI
import AppKit

struct WebResultRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let result: SearXNGResult
    let glassEnabled: Bool
    let query: String?
    let isHighlighted: Bool
    let onOpenInNewTab: (() -> Void)?
    let onOpen: () -> Void

    @State private var isHovering = false

    private var isHTTPS: Bool {
        URL(string: result.url)?.scheme?.lowercased() == "https"
    }

    private var publishedForDisplay: String? {
        result.formattedPublishedDate()
    }

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
            guard let snippet = result.content, !snippet.isEmpty else { return Text("") }
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
                    attr[attrRange].backgroundColor = SERPDesign.accentGreen.opacity(0.14)
                }
                searchRange = r.upperBound..<lowerSnippet.endIndex
            }
            return Text(attr)
        }()

        return inner
            .font(.system(size: 14))
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineSpacing(3)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command), let openNew = onOpenInNewTab {
                openNew()
            } else {
                onOpen()
            }
        } label: {
            SERPResultRowChrome(
                glassEnabled: glassEnabled,
                isHighlighted: isHighlighted,
                isHovering: isHovering
            ) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Site breadcrumb (favicon + host)
                        HStack(spacing: 8) {
                            FaviconView(pageURL: result.url, size: 18, cornerRadius: 4, loadRemote: true)

                            HStack(spacing: 4) {
                                Text(result.displayHost)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if isHTTPS {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(SERPDesign.accentGreen.opacity(0.8))
                                }

                                let path = result.displayPath
                                if !path.isEmpty {
                                    Text("›")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                    Text(path)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }

                        // Title — Google link blue
                        Text(result.title)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(
                                isHovering
                                    ? SERPDesign.linkColor(for: colorScheme).opacity(0.92)
                                    : SERPDesign.linkColor(for: colorScheme)
                            )
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .underline(isHovering, color: SERPDesign.linkColor(for: colorScheme).opacity(0.35))

                        // Snippet
                        snippetView

                        // Meta row (engines · date)
                        if result.enginesDisplay != nil || publishedForDisplay != nil {
                            HStack(spacing: 6) {
                                if let eng = result.enginesDisplay, !eng.isEmpty {
                                    Text(eng)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if let pub = publishedForDisplay {
                                    if result.enginesDisplay != nil {
                                        Text("·")
                                            .font(.caption2)
                                            .foregroundStyle(.quaternary)
                                    }
                                    Text(pub)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if let thumb = thumbnailURL {
                        CachedSearchThumbnail(
                            candidates: [thumb],
                            referer: result.url,
                            aspectRatio: 1,
                            contentMode: .fill,
                            useNaturalAspect: false
                        )
                        .frame(width: 88, height: 88)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        .accessibilityLabel("\(result.title), \(result.displayHost)")
        .accessibilityHint("Opens the result in the browser")
    }
}