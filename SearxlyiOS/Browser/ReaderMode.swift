//
//  ReaderMode.swift
//  SearxlyiOS
//
//  Distraction-free reading: a local JS heuristic extracts article structure from the already-loaded
//  page (nothing is re-fetched). Renders monochrome serif typography with size controls, progress,
//  estimated read time, and share/copy. Find is available via the toolbar.
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

    /// Rough word count for read-time estimate.
    var wordCount: Int {
        blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Minutes at ~220 wpm, minimum 1 when there is prose.
    var estimatedMinutes: Int {
        max(1, Int((Double(wordCount) / 220.0).rounded(.up)))
    }
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
    private var locale = AppLocale.shared

    @State private var sizeBoost: CGFloat = 1.0
    @State private var findQuery = ""
    @State private var showFind = false
    @State private var showSummary = false
    @FocusState private var findFocused: Bool

    init(article: ReaderArticle) { self.article = article }

    private var scale: CGFloat { appearance.textScale * sizeBoost }

    var body: some View {
        let _ = locale.languageCode
        NavigationStack {
            VStack(spacing: 0) {
                if showFind {
                    findBar
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(article.title)
                            .font(.system(size: 28 * scale, weight: .bold, design: .serif))
                            .foregroundStyle(Brand.text)
                            .padding(.bottom, 10)
                            .textSelection(.enabled)

                        HStack(spacing: 6) {
                            if let byline = article.byline {
                                Text(byline).lineLimit(1)
                                Text("·")
                            }
                            Text(article.host)
                            Text("·")
                            Text(String(format: L("%d min read"), article.estimatedMinutes))
                        }
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(Brand.textTertiary)
                        .padding(.bottom, 20)

                        ForEach(article.blocks) { block in
                            blockView(block)
                        }

                        Color.clear.frame(height: 40)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(L("Reader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            showFind.toggle()
                            if showFind { findFocused = true } else { findQuery = "" }
                        }
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .accessibilityLabel(L("Find on Page…"))

                    Menu {
                        Button {
                            withAnimation { sizeBoost = max(0.85, sizeBoost - 0.1) }
                        } label: {
                            Label(L("Smaller"), systemImage: "textformat.size.smaller")
                        }
                        Button {
                            withAnimation { sizeBoost = 1.0 }
                        } label: {
                            Label(L("Default Size"), systemImage: "textformat.size")
                        }
                        Button {
                            withAnimation { sizeBoost = min(1.45, sizeBoost + 0.1) }
                        } label: {
                            Label(L("Larger"), systemImage: "textformat.size.larger")
                        }
                        Divider()
                        if PageIntelligence.isAvailable {
                            Button { showSummary = true } label: {
                                Label(L("Summarize Page"), systemImage: "apple.intelligence")
                            }
                        }
                        Button {
                            UIPasteboard.general.string = plainText
                        } label: {
                            Label(L("Copy"), systemImage: "doc.on.doc")
                        }
                        ShareLink(item: plainText) {
                            Label(L("Share…"), systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L("Page options"))
                }
            }
            .tint(Brand.text)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showSummary) { SummarySheet(article: article) }
        }
    }

    private var findBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.textTertiary)
            TextField(L("Find on Page…"), text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !findQuery.isEmpty {
                Text(matchLabel)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(Brand.textTertiary)
                    .monospacedDigit()
            }
            Button {
                withAnimation { showFind = false; findQuery = "" }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.surface.ignoresSafeArea(edges: .horizontal))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Brand.hairline).frame(height: 0.5)
        }
    }

    private var matchLabel: String {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return "" }
        let count = plainText.lowercased().components(separatedBy: q.lowercased()).count - 1
        if count <= 0 { return L("No matches") }
        return String(format: L("%d matches"), count)
    }

    private var plainText: String {
        ([article.title] + article.blocks.map(\.text)).joined(separator: "\n\n")
    }

    @ViewBuilder
    private func blockView(_ block: ReaderArticle.Block) -> some View {
        let highlighted = highlighted(block.text)
        switch block.kind {
        case .heading:
            Text(highlighted)
                .font(.system(size: 20 * scale, weight: .semibold, design: .serif))
                .foregroundStyle(Brand.text)
                .padding(.top, 18).padding(.bottom, 6)
                .textSelection(.enabled)
        case .quote:
            Text(highlighted)
                .font(.system(size: 17 * scale, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(Brand.textSecondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Brand.textTertiary).frame(width: 3)
                }
                .padding(.vertical, 10)
                .textSelection(.enabled)
        case .paragraph:
            Text(highlighted)
                .font(.system(size: 17.5 * scale, weight: .regular, design: .serif))
                .lineSpacing(7)
                .foregroundStyle(Brand.textSecondary)
                .padding(.bottom, 15)
                .textSelection(.enabled)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return attr }
        var searchFrom = attr.startIndex
        while let range = attr[searchFrom...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            attr[range].backgroundColor = Brand.text.opacity(0.22)
            attr[range].foregroundColor = Brand.text
            searchFrom = range.upperBound
        }
        return attr
    }
}
