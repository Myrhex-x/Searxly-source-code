//
//  HoverLinkStatusStrip.swift
//  Searxly
//
//  Safari-style "where this link goes" strip for the NATIVE search-results page. The SERP is SwiftUI
//  (no WKWebView), so a plain SwiftUI overlay renders correctly here — unlike over a web page, where
//  the heavyweight WKWebView forces the web-page version to be an AppKit subview (see WebViewContainer).
//

import SwiftUI

/// Shared hovered-result URL. Result rows set it from their existing `.onHover`; the strip reads it.
@MainActor
@Observable
final class HoverLinkState {
    static let shared = HoverLinkState()
    private init() {}

    /// Destination of the search result under the cursor ("" when none).
    var url: String = ""

    func enter(_ u: String) { url = u }
    /// Clears only if still showing this row's URL — robust when moving cursor row-to-row.
    func leave(_ u: String) { if url == u { url = "" } }
}

struct HoverLinkStatusStrip: View {
    var body: some View {
        let url = HoverLinkState.shared.url
        Group {
            if !url.isEmpty {
                Text(url)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 540, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.1), value: url)
    }
}
