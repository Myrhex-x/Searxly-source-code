//
//  ReaderMode.swift
//  SearxlyiOS
//
//  A clean, distraction-free reading view. A JS heuristic (no third-party Readability payload)
//  picks the densest article container, then returns structured blocks (headings + paragraphs)
//  which we render natively in monochrome reading typography — respecting the app text-size
//  setting. Fully local: the page is already loaded; nothing is fetched or sent anywhere.
//

import SwiftUI
import WebKit

struct ReaderArticle: Equatable, Identifiable {
    let id = UUID()
    struct Block: Equatable, Identifiable {
        enum Kind: String { case heading, paragraph, quote }
        let id = UUID()
        let kind: Kind
        let text: String
    }
    let title: String
    let byline: String?
    let host: String
    let blocks: [Block]
}

@MainActor
enum ReaderExtractor {

    /// Returns nil when the page isn't article-shaped enough to render a useful reader view.
    static func extract(from webView: WKWebView) async -> ReaderArticle? {
        guard let raw = try? await webView.evaluateJavaScript(extractJS) as? [String: Any],
              let title = raw["title"] as? String,
              let blockDicts = raw["blocks"] as? [[String: String]],
              blockDicts.count >= 2 else { return nil }

        let blocks: [ReaderArticle.Block] = blockDicts.compactMap { dict in
            guard let kindRaw = dict["kind"], let kind = ReaderArticle.Block.Kind(rawValue: kindRaw),
                  let text = dict["text"], text.count > 1 else { return nil }
            return ReaderArticle.Block(kind: kind, text: text)
        }
        // Require some real prose, not just a couple of headings.
        let proseChars = blocks.filter { $0.kind == .paragraph }.reduce(0) { $0 + $1.text.count }
        guard proseChars >= 400 else { return nil }

        return ReaderArticle(
            title: title.isEmpty ? (webView.title ?? "") : title,
            byline: (raw["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            host: webView.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "",
            blocks: blocks
        )
    }

    private static let extractJS = """
    (function() {
        function txt(el) { return (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim(); }

        // Score candidate containers by paragraph text density; prefer semantic article/main.
        function pickContainer() {
            var candidates = Array.prototype.slice.call(
                document.querySelectorAll('article, main, [role="main"], .post, .article, .entry-content, #content, .content'));
            if (!candidates.length) candidates = [document.body];
            var best = null, bestScore = 0;
            candidates.forEach(function(el) {
                var ps = el.querySelectorAll('p');
                var score = 0;
                for (var i = 0; i < ps.length; i++) score += (ps[i].innerText || '').length;
                if (el.tagName === 'ARTICLE' || el.tagName === 'MAIN') score *= 1.3;
                if (score > bestScore) { bestScore = score; best = el; }
            });
            return best || document.body;
        }

        var container = pickContainer();
        var blocks = [];
        var SKIP = /(nav|footer|header|aside|form|button|figure|figcaption|table)/i;
        var nodes = container.querySelectorAll('h1, h2, h3, p, blockquote, li');
        for (var i = 0; i < nodes.length && blocks.length < 400; i++) {
            var n = nodes[i];
            if (n.closest && n.closest('nav, footer, aside, form')) continue;
            if (SKIP.test(n.parentElement ? n.parentElement.tagName : '')) continue;
            var t = txt(n);
            if (t.length < 2) continue;
            var tag = n.tagName.toLowerCase();
            var kind = (tag === 'h1' || tag === 'h2' || tag === 'h3') ? 'heading'
                     : (tag === 'blockquote') ? 'quote' : 'paragraph';
            // De-dupe consecutive identical text (common with overlays).
            if (blocks.length && blocks[blocks.length - 1].text === t) continue;
            blocks.push({ kind: kind, text: t });
        }

        function meta(sel, attr) {
            var m = document.querySelector(sel);
            return m ? (m.getAttribute(attr) || '') : '';
        }
        var title = meta('meta[property="og:title"]', 'content')
                 || (document.querySelector('h1') ? txt(document.querySelector('h1')) : '')
                 || document.title || '';
        var byline = meta('meta[name="author"]', 'content')
                  || meta('meta[property="article:author"]', 'content') || '';

        return { title: title, byline: byline, blocks: blocks };
    })();
    """
}

// MARK: - Reading view

struct ReaderView: View {
    let article: ReaderArticle
    @Environment(\.dismiss) private var dismiss
    private var appearance = AppearanceSettings.shared

    init(article: ReaderArticle) { self.article = article }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(article.title)
                        .font(.system(size: 27 * appearance.textScale, weight: .bold, design: .serif))
                        .foregroundStyle(Brand.text)
                        .padding(.bottom, 8)

                    HStack(spacing: 6) {
                        if let byline = article.byline {
                            Text(byline).lineLimit(1)
                            Text("·")
                        }
                        Text(article.host)
                    }
                    .font(.system(size: 12.5 * appearance.textScale))
                    .foregroundStyle(Brand.textTertiary)
                    .padding(.bottom, 18)

                    ForEach(article.blocks) { block in
                        blockView(block)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(L("Reader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("Done")) { dismiss() } }
            }
            .tint(Brand.text)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReaderArticle.Block) -> some View {
        switch block.kind {
        case .heading:
            Text(block.text)
                .font(.system(size: 20 * appearance.textScale, weight: .semibold, design: .serif))
                .foregroundStyle(Brand.text)
                .padding(.top, 16).padding(.bottom, 4)
        case .quote:
            Text(block.text)
                .font(.system(size: 17 * appearance.textScale, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(Brand.textSecondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Brand.textTertiary).frame(width: 3)
                }
                .padding(.vertical, 8)
        case .paragraph:
            Text(block.text)
                .font(.system(size: 17.5 * appearance.textScale, weight: .regular, design: .serif))
                .lineSpacing(6)
                .foregroundStyle(Brand.textSecondary)
                .padding(.bottom, 14)
        }
    }
}
