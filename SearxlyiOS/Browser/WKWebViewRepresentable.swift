//
//  WKWebViewRepresentable.swift
//  SearxlyiOS
//
//  iOS twin of the macOS WebViewRepresentable. Hosts a WKWebView created/owned by BrowserModel.
//  Named to avoid shadowing SwiftUI's own `WebView` type (introduced in iOS 26 / WebKit-for-SwiftUI).
//

import SwiftUI
import WebKit

struct WKWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    let model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.attachBoundaryBackGesture(to: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// WKWebView's own gesture (`allowsBackForwardNavigationGestures`, ON in BrowserModel) already gives
    /// the real Safari interactive back/forward *peek* for page↔page history — including forward. This
    /// adds the ONE thing it can't: when a left-edge back-swipe happens with no web history left, drop
    /// back to the native search results / home (`BrowserModel.goBack`).
    ///
    /// Crucially it's gated to ONLY begin at that boundary (`!canGoBack`): while the web view can still
    /// go back, this recognizer never even starts, so WebKit's interactive peek is completely untouched.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let model: BrowserModel
        private static let name = "searxlyBoundaryBack"

        init(model: BrowserModel) { self.model = model }

        func attachBoundaryBackGesture(to webView: WKWebView) {
            if webView.gestureRecognizers?.contains(where: { $0.name == Self.name }) == true { return }
            let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeBack))
            edge.edges = .left
            edge.name = Self.name
            edge.delegate = self
            webView.addGestureRecognizer(edge)
        }

        @objc private func handleEdgeBack(_ g: UIScreenEdgePanGestureRecognizer) {
            guard g.state == .ended, let view = g.view else { return }
            // A committed rightward swipe (or a flick) — goBack() here means "no web history left", so it
            // returns to the native results / home.
            if g.translation(in: view).x > 24 || g.velocity(in: view).x > 250 { model.goBack() }
        }

        // Only participate at the web-history boundary. While WKWebView can still go back, stand down
        // entirely (return false) so its native interactive peek owns the gesture.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !model.webView.canGoBack
        }

        // Never block, and be blocked by, WebKit's own recognizers — coexist.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
