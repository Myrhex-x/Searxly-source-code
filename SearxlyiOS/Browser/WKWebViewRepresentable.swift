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

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
