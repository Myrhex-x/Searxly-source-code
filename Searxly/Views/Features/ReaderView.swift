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

    @AppStorage("reduceLiquidGlass") private var reduceLiquidGlass = false
    @Environment(\.colorScheme) private var colorScheme

    // Reading preferences persist across sessions (a reader you re-tune on every open isn't one).
    @AppStorage("Reader.fontSize") private var fontSize: Double = 17
    @AppStorage("Reader.useSerif") private var useSerif = false

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
