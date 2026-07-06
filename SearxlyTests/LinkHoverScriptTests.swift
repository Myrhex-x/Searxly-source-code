//
//  LinkHoverScriptTests.swift
//  SearxlyTests
//
//  Verifies the link-hover JS→native bridge headlessly: the real injected reporter script must, on a
//  mouseover over an <a href>, post the destination URL to the `linkHover` message handler. This
//  isolates the bridge from the on-screen status strip (which is a separate AppKit view).
//

import XCTest
import WebKit
@testable import Searxly

@MainActor
final class LinkHoverScriptTests: XCTestCase {

    private final class MsgHandler: NSObject, WKScriptMessageHandler {
        var onMessage: ((String) -> Void)?
        func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
            onMessage?((m.body as? String) ?? "<non-string>")
        }
    }

    private final class NavDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { onFinish?() }
    }

    func testHoverScriptReportsLinkHref() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: WebViewFactory.linkHoverReporterSource,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        let handler = MsgHandler()
        config.userContentController.add(handler, name: "linkHover")

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let nav = NavDelegate()
        webView.navigationDelegate = nav

        let loaded = expectation(description: "page loaded")
        nav.onFinish = { loaded.fulfill() }
        webView.loadHTMLString(
            "<html><body style='margin:0'><a id='lnk' href='https://example.com/page'>a link</a></body></html>",
            baseURL: URL(string: "https://test.local/")
        )
        wait(for: [loaded], timeout: 10)

        let got = expectation(description: "hover message received")
        var received: String?
        handler.onMessage = { body in
            if body == "https://example.com/page" {
                received = body
                got.fulfill()
            }
        }
        // Synthetic hover over the link — should travel script → postMessage → handler.
        webView.evaluateJavaScript(
            "var a=document.getElementById('lnk');a.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));",
            completionHandler: nil
        )
        wait(for: [got], timeout: 10)
        XCTAssertEqual(received, "https://example.com/page", "Hover over a link must post its href to the linkHover handler")
    }
}
