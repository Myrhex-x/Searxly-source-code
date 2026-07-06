//
//  ReaderView.swift
//  Searxly
//
//  Clean, distraction-free reading mode. Renders via WKWebView for full fidelity
//  (tables, code blocks, images) without blocking the main thread.
//

import SwiftUI
import WebKit

struct ReaderView: View {
    let title: String
    let html: String
    let onDismiss: () -> Void
    var onAskAI: (() -> Void)? = nil
    /// Hands the produced summary off to the full chat (summary, page title).
    var onTalkToSearxly: ((String, String) -> Void)? = nil

    @AppStorage("reduceLiquidGlass") private var reduceLiquidGlass = false
    @Environment(\.colorScheme) private var colorScheme

    // Reading preferences persist across sessions (a reader you re-tune on every open isn't one).
    @AppStorage("Reader.fontSize") private var fontSize: Double = 17
    @AppStorage("Reader.useSerif") private var useSerif = false

    // In-reader AI summary (Siri-style), produced from the cleaned reader content.
    @State private var summary: String = ""
    @State private var isSummarizing = false
    @State private var showSummary = false
    @State private var summaryTask: Task<Void, Never>? = nil

    private var toolbarMaterial: Material {
        reduceLiquidGlass ? .regularMaterial : .ultraThinMaterial
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.isEmpty ? "Reader" : title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 10) {
                    Button { fontSize = max(13, fontSize - 1) } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Text("\(Int(fontSize))pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34)
                        .monospacedDigit()

                    Button { fontSize = min(26, fontSize + 1) } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Divider().frame(height: 16)

                    Button { useSerif.toggle() } label: {
                        Image(systemName: useSerif ? "textformat" : "textformat.alt")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(useSerif ? "Switch to sans-serif" : "Switch to serif")

                    // AI affordances exist only while the AI program ships (release kill switch —
                    // see AIFeatures). With it off, Reader is a pure on-device reading surface.
                    if AIFeatures.programEnabled {
                        Divider().frame(height: 16)

                        Button(action: toggleSummary) {
                            Label("Summarize", systemImage: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Summarize this article with Searxly AI")

                        if let askAI = onAskAI {
                            Button(action: askAI) {
                                Label("Ask AI", systemImage: "bubble.left.and.bubble.right")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Open Searxly AI chat — ask questions about this page")
                        }
                    }

                    Divider().frame(height: 16)

                    Button("Done", action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(toolbarMaterial)

            Divider()

            ReaderWebView(
                html: html,
                title: title,
                fontSize: CGFloat(fontSize),
                useSerif: useSerif,
                colorScheme: colorScheme
            )
        }
        // Near-fullscreen: large ideal size (macOS clamps the sheet to the screen).
        .frame(minWidth: 1000, idealWidth: 1440, maxWidth: .infinity,
               minHeight: 700, idealHeight: 980, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if showSummary {
                summaryPanel
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showSummary)
        .onDisappear { summaryTask?.cancel() }
    }

    // MARK: - In-reader summary panel (Siri-style, Liquid Glass)

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                SearxlyChatMark(color: WalletTheme.textSecondary, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                Text("Searxly AI")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalletTheme.textPrimary)
                Text("· Summary")
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.textSecondary)
                if LocalIntelligenceManager.shared.preferences.searxlyAIEnabled
                    && LocalIntelligenceManager.shared.preferences.useSearxlyAI {
                    Text("Cloud")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WalletTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(WalletTheme.surfaceStrong))
                        .help("Generated on Searxly's cloud — this content is sent off your Mac.")
                }
                Spacer()
                Button {
                    summaryTask?.cancel()
                    showSummary = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WalletTheme.textSecondary)
                        .padding(5)
                        .background(Circle().fill(WalletTheme.surfaceStrong))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().overlay(WalletTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if summary.isEmpty && isSummarizing {
                        TypingDots(color: WalletTheme.textSecondary).padding(.vertical, 2)
                    } else {
                        Text(summary)
                            .textSelection(.enabled)
                            .font(.callout)
                            .foregroundStyle(WalletTheme.textPrimary.opacity(0.94))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 240)

            Divider().overlay(WalletTheme.hairline)

            HStack(spacing: 10) {
                Button {
                    let polished = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !polished.isEmpty else { return }
                    summaryTask?.cancel()
                    onTalkToSearxly?(polished, title)
                } label: {
                    Label("Talk to Searxly", systemImage: "bubble.left.and.bubble.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(WalletTheme.primaryText(enabled: true))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(WalletTheme.primaryFill(enabled: true)))
                }
                .buttonStyle(.plain)
                .disabled(summary.isEmpty)

                Spacer()

                Button {
                    let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.callout)
                        .foregroundStyle(WalletTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(WalletTheme.surfaceStrong))
                }
                .buttonStyle(.plain)
                .disabled(summary.isEmpty)
                .help("Copy summary")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: 560)
        .background {
            if reduceLiquidGlass {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WalletTheme.canvasRaised)
            }
        }
        .searxlyGlass(reduceLiquidGlass ? .clear : .regular,
                      in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(WalletTheme.hairline, lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 10)
    }

    // MARK: - Summary generation (hardened against prompt injection)

    private func toggleSummary() {
        if showSummary {
            summaryTask?.cancel()
            showSummary = false
        } else {
            startSummary()
        }
    }

    private func startSummary() {
        showSummary = true
        summary = ""
        isSummarizing = true

        let manager = LocalIntelligenceManager.shared
        manager.warmUpIfNeeded()
        guard manager.canUseFeatures else {
            isSummarizing = false
            summary = "Turn on Searxly AI in Settings to summarize."
            return
        }

        // Reader HTML is already cleaned, but still treat it as UNTRUSTED: strip to text, then run it
        // through the same PageContentGuard defenses as the right-click page summary (no tools, nonce
        // framing, role defang, non-actionable output).
        let text = PageContentGuard.sanitize(Self.plainText(fromHTML: html))
        guard !text.isEmpty else {
            isSummarizing = false
            summary = "There's no readable text to summarize."
            return
        }

        let isCloud = manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI
        let nonce = PageContentGuard.makeNonce()
        let suspected = PageContentGuard.looksLikeInjection(text)
        let system = PageContentGuard.systemPrompt(nonce: nonce, injectionSuspected: suspected, isCloud: isCloud, task: .summarizePage)
        let prompt = PageContentGuard.userBlock(content: text, nonce: nonce, title: title, url: "", task: .summarizePage)

        let engine = ConversationEngine()
        summaryTask = Task { @MainActor in
            do {
                for try await chunk in engine.generateStream(prompt: prompt, instructions: system) {
                    if Task.isCancelled { return }
                    summary += chunk
                }
                summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                isSummarizing = false
            } catch {
                isSummarizing = false
                if summary.isEmpty {
                    let msg = (error as NSError).localizedDescription
                    summary = msg.isEmpty ? "Searxly AI couldn’t summarize this. Try again." : msg
                }
            }
        }
    }

    /// Strips reader HTML down to plain text for the model (tags removed, basic entities decoded).
    /// PageContentGuard.sanitize then collapses whitespace + caps length.
    static func plainText(fromHTML html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">")
             .replacingOccurrences(of: "&quot;", with: "\"")
             .replacingOccurrences(of: "&#39;", with: "'")
             .replacingOccurrences(of: "&nbsp;", with: " ")
        return s
    }
}

// MARK: - WKWebView renderer

private struct ReaderWebView: NSViewRepresentable {
    let html: String
    let title: String
    let fontSize: CGFloat
    let useSerif: Bool
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastSignature: String = ""

        /// Reader renders UNTRUSTED page HTML as a static document. Link clicks leave the reader and
        /// open as a normal browser tab (same `.openExternalURL` route as links from other apps) —
        /// the reader webview itself never navigates anywhere.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                decisionHandler(.cancel)
                NotificationCenter.default.post(name: .openExternalURL, object: url)
                return
            }
            decisionHandler(.allow)
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Static article HTML only: no scripts run (the extracted content is untrusted), and nothing
        // the reader loads (remote images) touches the browsing profile's storage.
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        // Load the article immediately so it's visible the moment Reader opens.
        loadIfNeeded(wv, context: context)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // CRITICAL: only reload when the content or styling actually changed. SwiftUI calls
        // updateNSView on every parent state change (e.g. while the AI summary streams token-by-token),
        // and reloading loadHTMLString each time blanks the article. Guard against that.
        loadIfNeeded(wv, context: context)
    }

    private func loadIfNeeded(_ wv: WKWebView, context: Context) {
        let signature = "\(colorScheme)|\(Int(fontSize))|\(useSerif)|\(title)|\(html.count)"
        guard signature != context.coordinator.lastSignature else { return }
        context.coordinator.lastSignature = signature
        wv.loadHTMLString(buildHTML(), baseURL: nil)
    }

    private func buildHTML() -> String {
        let isDark = colorScheme == .dark
        // Monochrome, matching the app chrome (BrowserMenuTheme / WalletTheme): near-black canvas in
        // dark, white in light. Links are INK + underline — Searxly never decorates with color.
        let bg      = isDark ? "#0b0b0d" : "#ffffff"
        let fg      = isDark ? "#f2f2f7" : "#1d1d1f"
        let link    = fg
        let subtle  = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)"
        let border  = isDark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.1)"
        let font    = useSerif
            ? "'Georgia', 'Times New Roman', serif"
            : "-apple-system, 'SF Pro Text', BlinkMacSystemFont, sans-serif"

        let css = """
        * { box-sizing: border-box; margin: 0; padding: 0; }
        html { height: 100%; }
        body {
            background: \(bg);
            color: \(fg);
            font-family: \(font);
            font-size: \(Int(fontSize))px;
            line-height: 1.75;
            max-width: 720px;
            margin: 0 auto;
            padding: 36px 44px 100px;
            -webkit-font-smoothing: antialiased;
        }
        h1 { font-size: 1.75em; line-height: 1.25; margin: 0 0 0.6em; }
        h2 { font-size: 1.35em; line-height: 1.3; margin: 1.8em 0 0.5em; }
        h3 { font-size: 1.15em; margin: 1.5em 0 0.4em; }
        h4, h5, h6 { margin: 1.2em 0 0.35em; }
        p { margin: 0.9em 0; }
        a { color: \(link); text-decoration: underline; text-underline-offset: 3px; opacity: 0.92; }
        a:hover { opacity: 1; }
        img { max-width: 100%; height: auto; border-radius: 8px; margin: 14px 0; display: block; }
        /* Reader shows text, not chrome: never render icons/controls/embeds (prevents giant share-icon blobs). */
        svg, button, input, select, textarea, form, iframe, video, audio, object, embed { display: none !important; }
        pre {
            background: \(subtle);
            padding: 14px 18px;
            border-radius: 8px;
            overflow-x: auto;
            margin: 1.1em 0;
            font-size: 0.87em;
        }
        code {
            background: \(subtle);
            padding: 0.15em 0.42em;
            border-radius: 4px;
            font-size: 0.87em;
        }
        pre code { background: none; padding: 0; }
        blockquote {
            border-left: 3px solid \(border);
            margin: 1.3em 0;
            padding: 0.5em 0 0.5em 1.3em;
            opacity: 0.82;
        }
        ul, ol { padding-left: 1.8em; margin: 0.85em 0; }
        li { margin: 0.3em 0; }
        table { border-collapse: collapse; width: 100%; margin: 1.1em 0; }
        th, td { padding: 8px 14px; border: 1px solid \(border); text-align: left; }
        th { background: \(subtle); font-weight: 600; }
        hr { border: none; border-top: 1px solid \(border); margin: 1.8em 0; }
        figure { margin: 1.2em 0; }
        figcaption { font-size: 0.85em; opacity: 0.65; margin-top: 6px; }
        """

        let titleHTML = title.isEmpty ? "" : "<h1>\(escapeHTML(title))</h1>\n"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head>
        <body>
        \(titleHTML)\(html)
        </body>
        </html>
        """
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

#Preview {
    ReaderView(
        title: "Example Article",
        html: "<p>This is a <strong>clean</strong> reading experience.</p><p>More content here for testing line length and readability.</p>",
        onDismiss: {}
    )
}
