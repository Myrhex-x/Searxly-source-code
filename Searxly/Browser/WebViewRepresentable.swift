//
//  WebViewRepresentable.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Reusable WKWebView wrapper for the embedded browser (Phases 4-11)
//

import SwiftUI
import os
import WebKit

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    @Binding var isLoading: Bool
    @Binding var estimatedProgress: Double
    @Binding var pageTitle: String
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool


    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WebViewContainer {
        webView.navigationDelegate = context.coordinator
        // UI delegate routes new-window requests (target="_blank", window.open, "Open Link in New Tab")
        // into Searxly tabs. Without it WKWebView silently drops those navigations.
        webView.uiDelegate = context.coordinator

        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "adblockDiagnostic")
        ucc.add(context.coordinator, name: "adblockDiagnostic")

        // Link-hover reporter → status strip (bottom-left "where this link goes").
        ucc.removeScriptMessageHandler(forName: "linkHover")
        ucc.add(context.coordinator, name: "linkHover")

        // Wallet provider bridge (EIP-1193). Uses the reply-handler variant so JS can await
        // the result directly. Registered in the page content world so window.ethereum sees it.
        //
        // PRIVACY: the native handler is reachable from page JS via
        // window.webkit.messageHandlers.searxlyWallet directly — even without the injected
        // provider script. So we must gate the HANDLER itself with the exact same conditions
        // used to inject the script in WebViewFactory: a wallet must exist, site exposure must
        // be enabled, AND this must be a standard (persistent) tab. Otherwise a page in a
        // Private tab (or after the user disables "Let websites connect") could call
        // eth_accounts directly and read the address, defeating those guarantees.
        ucc.removeScriptMessageHandler(forName: "searxlyWallet", contentWorld: .page)
        let isStandardTab = webView.configuration.websiteDataStore.isPersistent
        let walletConfigured = UserDefaults.standard.bool(forKey: WalletConfig.Keys.walletConfigured)
        if isStandardTab && walletConfigured && WalletFeatures.dappProvider {
            ucc.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "searxlyWallet")
            WalletProviderBridge.shared.register(webView)
        }

        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.title), options: .new, context: nil)
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.canGoBack), options: .new, context: nil)
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.canGoForward), options: .new, context: nil)

        context.coordinator.observedWebView = webView

        let container = WebViewContainer(webView: webView)
        context.coordinator.observedContainer = container
        return container
    }

    func updateNSView(_ nsView: WebViewContainer, context: Context) {
        let coordinator = context.coordinator
        if !coordinator.hasSeededBackForward {
            coordinator.hasSeededBackForward = true
            DispatchQueue.main.async {
                coordinator.parent.canGoBack = nsView.webView.canGoBack
                coordinator.parent.canGoForward = nsView.webView.canGoForward
            }
        }
    }

    static func dismantleNSView(_ nsView: WebViewContainer, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func requestStabilization() {
        webView.evaluateJavaScript("""
        (function(){
          try {
            window.dispatchEvent(new Event('resize'));
            void document.documentElement.offsetWidth;
          } catch(e){}
        })();
        """, completionHandler: nil)
    }

    func performFind(_ searchTerm: String) {
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps = true
        webView.find(searchTerm, configuration: config) { _ in }
    }

    func exitFindMode() {
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewRepresentable
        weak var observedWebView: WKWebView?
        weak var observedContainer: WebViewContainer?

        var hasSeededBackForward = false
        var didTeardown = false
        /// Timestamp of the last auto-reload triggered by a WebContent process crash. Used to rate-limit
        /// recovery so a page that deterministically kills its renderer can't spin in a reload loop.
        var lastWebContentCrashReload: Date?
        var youtubeRecoveryTimer: Timer?
        var youtubeHighFreqSource: DispatchSourceTimer?
        var hasReappliedAdBlockLate = false
        var appliedAdBlockRuleListIDs = Set<ObjectIdentifier>()

        /// URL cancelled because the Maximum-Privacy kill switch was closed; reloaded when protection returns.
        var lastBlockedURL: URL?

        func isYouTubeVideoPage(_ url: URL?) -> Bool {
            guard let url = url else { return false }
            let host = url.host?.lowercased() ?? ""
            guard host.contains("youtube.com") || host.contains("youtu.be") else { return false }
            let path = url.path.lowercased()
            if path.hasPrefix("/watch") || path.hasPrefix("/shorts") || path.hasPrefix("/live") {
                return true
            }
            if host.contains("youtu.be") && !path.isEmpty && path != "/" {
                return true
            }
            return false
        }

        init(_ parent: WebViewRepresentable) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reapplyAdBlockRules),
                name: AdBlockNotifications.rulesReady,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(protectionStateChanged),
                name: PrivacyGate.protectionStateChangedNotification,
                object: nil
            )
        }

        func teardown() {
            guard !didTeardown else { return }
            didTeardown = true

            stopYouTubeRecoveryTimer()

            if let webView = observedWebView {
                webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
                webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
                webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
                webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack))
                webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward))
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "adblockDiagnostic")
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkHover")
            }

            NotificationCenter.default.removeObserver(self, name: AdBlockNotifications.rulesReady, object: nil)
            NotificationCenter.default.removeObserver(self, name: PrivacyGate.protectionStateChangedNotification, object: nil)
            observedWebView = nil
            observedContainer = nil
        }

        deinit {
            if !didTeardown {
                youtubeRecoveryTimer?.invalidate()
                youtubeHighFreqSource?.cancel()
            }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            guard let webView = object as? WKWebView else { return }
            DispatchQueue.main.async {
                switch keyPath {
                case #keyPath(WKWebView.estimatedProgress):
                    self.parent.estimatedProgress = webView.estimatedProgress
                case #keyPath(WKWebView.title):
                    let liveTitle = webView.title ?? ""
                    self.parent.pageTitle = liveTitle
                    if let u = webView.url {
                        NotificationCenter.default.post(
                            name: BrowserState.historyTitleSnapshotNotification,
                            object: nil,
                            userInfo: ["url": u, "title": liveTitle]
                        )
                    }
                    if let url = self.observedWebView?.url, url.host?.contains("youtube") == true || url.host?.contains("youtu.be") == true {
                        self.observedWebView?.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
                        self.observedWebView?.evaluateJavaScript("""
                        (function() {
                            document.querySelectorAll('video').forEach(v => {
                                v.style.setProperty('display','block','important');
                                v.style.setProperty('visibility','visible','important');
                                v.style.setProperty('opacity','1','important');
                            });
                            const bad = document.querySelectorAll('ytd-enforcement-message-view-model, .ytp-error, [class*="enforcement"]');
                            bad.forEach(el => { el.style.cssText = 'display:none!important;visibility:hidden!important;'; });
                        })();
                        """, completionHandler: nil)

                        if let wv = self.observedWebView { self.enterYouTubeSafeMode(on: wv) }
                    }
                case #keyPath(WKWebView.url):
                    self.parent.currentURL = webView.url
                    if let url = webView.url, !(url.host?.contains("youtube") == true || url.host?.contains("youtu.be") == true) {
                        self.stopYouTubeRecoveryTimer()
                    } else if let url = webView.url, (url.host?.contains("youtube") == true || url.host?.contains("youtu.be") == true) {
                        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
                        self.enterYouTubeSafeMode(on: webView)
                        if !self.isYouTubeVideoPage(url) {
                            self.stopYouTubeRecoveryTimer()
                            self.youtubeHighFreqSource?.cancel()
                            self.youtubeHighFreqSource = nil
                        }
                    }
                case #keyPath(WKWebView.canGoBack):
                    self.parent.canGoBack = webView.canGoBack
                case #keyPath(WKWebView.canGoForward):
                    self.parent.canGoForward = webView.canGoForward
                default: break
                }
            }
        }
    }
}

typealias WebView = WebViewRepresentable