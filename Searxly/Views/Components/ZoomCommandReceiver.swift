//
//  ZoomCommandReceiver.swift
//  Searxly
//
//  Bridges the View-menu zoom commands (posted from SearxlyApp) to BrowserState's page-zoom actions.
//
//  Why menu commands instead of hidden-button .keyboardShortcut: a focused WKWebView is the first
//  responder and shadows view-level keyboard shortcuts, so ⌘+/⌘−/⌘0 never reached the hidden zoom
//  buttons while a page was focused. Main-menu items fire via NSApplication.performKeyEquivalent
//  before first-responder dispatch, so they always work — the same path Safari's View ▸ Zoom uses.
//

import SwiftUI

extension Notification.Name {
    static let zoomInCommand    = Notification.Name("Searxly.zoomIn")
    static let zoomOutCommand   = Notification.Name("Searxly.zoomOut")
    static let zoomResetCommand = Notification.Name("Searxly.zoomReset")
}

struct ZoomCommandReceiver: View {
    let browserState: BrowserState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .zoomInCommand))    { _ in browserState.zoomIn() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOutCommand))   { _ in browserState.zoomOut() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomResetCommand)) { _ in browserState.resetZoom() }
            .accessibilityHidden(true)
    }
}
