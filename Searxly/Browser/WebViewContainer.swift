//
//  WebViewContainer.swift
//  Searxly
//
//  Dedicated NSView host for WKWebView.
//  Responsibilities:
//  - Guarantee the WKWebView always has correct bounds matching its SwiftUI parent
//    (addresses the core cause of "super wide" / broken initial layout on pages like speedtest).
//  - Dispatch 'resize' events + force reflow into the web content on size changes and key lifecycle moments.
//  - Provide an explicit stabilizeLayout() hook for the representable and navigation delegate.
//
//  This is the single place that owns frame syncing and layout-driven web content stabilization.
//  All WKWebViews (standard + private, fresh + woken from hibernation) benefit automatically
//  because they are always hosted through WebViewRepresentable → WebViewContainer.
//

import AppKit
import WebKit

final class WebViewContainer: NSView {

    let webView: WKWebView

    private var stabilizationWorkItem: DispatchWorkItem?

    // MARK: - Link-hover status strip (Safari-style "where this link goes")
    //
    // Implemented as an AppKit subview *above* the WKWebView rather than a SwiftUI overlay: a
    // WKWebView is a heavyweight NSView that composites above sibling SwiftUI content, so a SwiftUI
    // overlay would be hidden behind it. This subview is added after the webView, so it draws on top.
    // Driven directly from the linkHover message handler via showHoverURL(_:).

    private lazy var hoverLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.drawsBackground = true
        label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor.separatorColor.cgColor
        label.layer?.masksToBounds = true
        label.isHidden = true
        return label
    }()

    /// Shows (or hides, when empty) the destination of the link under the cursor, pinned bottom-left
    /// above the page. Called on the main thread from the linkHover script-message handler.
    func showHoverURL(_ url: String) {
        guard !url.isEmpty else {
            hoverLabel.isHidden = true
            return
        }
        if hoverLabel.superview == nil {
            addSubview(hoverLabel)   // added after webView ⇒ z-ordered above it
        }
        hoverLabel.stringValue = "  \(url)  "
        hoverLabel.isHidden = false
        layoutHoverLabel()
    }

    private func layoutHoverLabel() {
        guard !hoverLabel.isHidden else { return }
        hoverLabel.sizeToFit()
        let maxWidth = min(bounds.width - 16, 560)
        let width = min(hoverLabel.frame.width, maxWidth)
        let height = hoverLabel.frame.height + 6
        // Origin is bottom-left (this NSView is not flipped), so y = 8 sits just above the bottom edge.
        hoverLabel.frame = NSRect(x: 8, y: 8, width: max(width, 24), height: height)
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)

        // Use autoresizingMask so the webview automatically follows the container's size.
        // This is more reliable than Auto Layout constraints in SwiftUI NSViewRepresentable
        // scenarios where the parent view's frame is driven directly by the layout engine.
        // We still do explicit syncs in setFrameSize + layout for belt-and-suspenders.
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout synchronization (the heart of the wide-page fix)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // SwiftUI often sets the frame directly on the NSViewRepresentable's view.
        // Catch it here so the webview gets the size immediately and we can notify the page.
        webView.frame = bounds
        scheduleStabilization()
    }

    override func layout() {
        super.layout()

        // Force exact bounds on the webview. This ensures that even if the representable
        // received a size update after the page started its first layout/paint/JS measurements,
        // the web content sees the correct viewport width.
        if webView.frame.size != bounds.size {
            webView.frame = bounds
        }

        // Throttled stabilization: tell the page its container size may have changed.
        // Critical for responsive sites, canvas measurements, media queries, and SPAs
        // that snapshot window dimensions early.
        scheduleStabilization()

        // Keep the hover strip pinned bottom-left as the pane resizes.
        layoutHoverLabel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // The view now has a real window and (very soon) real size.
            // Give SwiftUI one runloop tick to settle the final bounds, then stabilize.
            // We do a stronger multi-pass stabilization on first attach.
            DispatchQueue.main.async { [weak self] in
                self?.stabilizeLayout(repeats: 3)
            }
        }
    }

    // MARK: - Public stabilization API (called from representable + coordinator)

    /// Explicitly sync frame and push a resize + reflow into the web content.
    /// Safe to call at any time (e.g. after tab wake, explicit reload, or from didFinish).
    /// Pass repeats > 0 to schedule additional stabilization passes (helps JS-heavy sites
    /// like speedtest that do measurement + positioning in later frames or after data load).
    func stabilizeLayout(repeats: Int = 0) {
        webView.frame = bounds
        performImmediateStabilization()

        if repeats > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.webView.frame = self?.bounds ?? .zero
                self?.performImmediateStabilization()
                if repeats > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        self?.webView.frame = self?.bounds ?? .zero
                        self?.performImmediateStabilization()
                        if repeats > 2 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                                self?.webView.frame = self?.bounds ?? .zero
                                self?.performImmediateStabilization()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    private func scheduleStabilization() {
        stabilizationWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.performImmediateStabilization()
        }
        stabilizationWorkItem = work

        // ~1 frame throttle. Enough to coalesce rapid SwiftUI layout passes
        // (sidebar toggle, window resize) without perceptible lag.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    private func performImmediateStabilization() {
        // The common case (virtually every site) only needs to be told its viewport changed — a single
        // `resize` event. The page's own responsive CSS/JS handles the rest. This runs on every layout()/
        // setFrameSize (≈ continuously during a window/sidebar drag), so keeping it cheap matters.
        //
        // Only a small set of quirky, JS-measured single-page UIs (speedtest gauges etc.) need the heavy
        // width-forcing + sub-pixel reflow perturbation. Forcing html/body width:100% !important on every
        // site is both expensive (forced synchronous reflow) and risky (it can fight legitimate layouts),
        // so we gate it behind a host allow-list instead of paying it everywhere.
        //
        // YouTube is excluded from the heavy path entirely: the width forcing + nudge has been observed to
        // collapse the player's computed height to 0 (audio plays, video invisible). YT gets only the
        // lightweight resize ping. (Quality help lives in WebViewRepresentable.enterYouTubeSafeMode.)
        let host = (webView.url?.host ?? "").lowercased()
        let needsAggressiveLayout = Self.aggressiveLayoutHostFragments.contains { host.contains($0) }

        let js = needsAggressiveLayout ? Self.aggressiveStabilizeJS : Self.lightResizeJS
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Stabilization JS payloads

    /// Hosts whose layout genuinely needs the aggressive width-forcing + reflow perturbation. These are
    /// JS-measured, centered single-page UIs that latch a bad layout rect on first paint inside our
    /// sidebar-constrained pane. Keep this list short — everything else uses `lightResizeJS`.
    static let aggressiveLayoutHostFragments: [String] = ["speedtest.net", "speedtest.com"]

    /// The cheap default: just notify the page its viewport changed. No style mutation, no forced reflow.
    private static let lightResizeJS = """
    (function(){
        try {
            window.dispatchEvent(new Event('resize'));
            if (window.visualViewport) { try { window.dispatchEvent(new Event('resize')); } catch (_) {} }
        } catch (_) {}
    })();
    """

    /// The heavy treatment, reserved for `aggressiveLayoutHostFragments`. Forces the root blocks to the
    /// full pane width + auto margins and does a sub-pixel width perturbation to kick lazy/RAF-based
    /// centering and measurement code that missed the first resize.
    private static let aggressiveStabilizeJS = """
    (function() {
        try {
            const win = window;
            const docEl = document.documentElement;
            const body = document.body;

            docEl.style.setProperty('width', '100%', 'important');
            if (body) {
                body.style.setProperty('width', '100%', 'important');
                body.style.setProperty('margin-left', 'auto', 'important');
                body.style.setProperty('margin-right', 'auto', 'important');
            }

            const origWidth = docEl.style.width;
            const measured = win.innerWidth || docEl.clientWidth || 0;
            if (measured > 0) {
                docEl.style.width = (measured + 0.5) + 'px';
                void docEl.offsetWidth;
                if (body) void body.offsetWidth;
                docEl.style.width = origWidth || '';
                void docEl.offsetWidth;
            }

            win.dispatchEvent(new Event('resize'));
            if (win.visualViewport) { try { win.dispatchEvent(new Event('resize')); } catch (_) {} }
            void docEl.offsetWidth;
            if (body) void body.offsetWidth;
            win.dispatchEvent(new Event('resize'));
        } catch (_) {
            // Never let layout JS break the page or the host.
        }
    })();
    """
}
