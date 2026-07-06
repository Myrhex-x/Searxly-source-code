//
//  ScreenCaptureProtection.swift
//  Searxly
//
//  Excludes the hosting window from screen capture — screenshots, screen recording, and screen
//  sharing (Zoom/QuickTime/Teams/…) — while a view marked `.screenCaptureProtected()` is on screen.
//
//  Used for crown-jewel secrets: the wallet seed phrase and any revealed password. For a self-custody
//  wallet, a recovery phrase that leaks into a screen recording or a shared screen is a total
//  compromise, so we set the window's `sharingType = .none` for as long as the secret is visible and
//  restore it (`.readOnly`, the default) when it goes away. This is the same mechanism password
//  managers use; it makes the window render black in any capture.
//

import SwiftUI
import AppKit

private struct ScreenCaptureProtector: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ProtectorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProtectorView)?.protect()
    }

    final class ProtectorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            protect()
        }

        func protect() {
            window?.sharingType = .none
        }

        // Restore normal sharing when this protector is removed from its window (the secret view was dismissed).
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { window?.sharingType = .readOnly }
        }
    }
}

extension View {
    /// Excludes the hosting window from screenshots / screen recording / screen sharing while this view
    /// is on screen. Apply to any view that displays the wallet seed phrase or a revealed password.
    func screenCaptureProtected() -> some View {
        background(
            ScreenCaptureProtector()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}
