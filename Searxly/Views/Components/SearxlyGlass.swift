//
//  SearxlyGlass.swift
//  Searxly
//
//  Liquid Glass compatibility layer.
//
//  Apple's Liquid Glass API (`View.glassEffect(_:in:)` and the `Glass` value type) is macOS 26+.
//  Searxly deploys down to macOS 15 (all Apple Silicon Macs), so every call site goes through this
//  one wrapper instead of touching `glassEffect` directly:
//
//    - macOS 26+  → the real `glassEffect` with the exact same styling (premium look unchanged).
//    - macOS 15…25 → a frosted `.ultraThinMaterial` background in the same shape (graceful fallback).
//
//  Centralizing it here means there is exactly one `#available(macOS 26.0, *)` check for glass in the
//  whole app, and the design keeps working — just without the live Liquid Glass refraction — on older
//  macOS. Apple Silicon only; there is no Intel path to consider.
//

import SwiftUI

/// Searxly's own glass-style selector (available on every supported OS). It mirrors the three `Glass`
/// values the app actually uses so call sites can keep their existing conditional expressions verbatim,
/// only swapping `.regular.interactive()` → `.interactive`.
enum SearxlyGlassStyle {
    /// `Glass.regular.interactive()` on macOS 26+ (responds to hover/press). Frosted fill otherwise.
    case interactive
    /// `Glass.regular` on macOS 26+. Frosted fill otherwise.
    case regular
    /// `Glass.clear` on macOS 26+ (no visible material). Nothing on the fallback.
    case clear
}

extension View {
    /// Liquid Glass when available (macOS 26+), with a frosted-material fallback on older macOS.
    /// Drop-in replacement for `.glassEffect(_:in:)` — see `SearxlyGlass.swift` for the rationale.
    @ViewBuilder
    func searxlyGlass<S: Shape>(_ style: SearxlyGlassStyle, in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            switch style {
            case .interactive:
                self.glassEffect(.regular.interactive(), in: shape)
            case .regular:
                self.glassEffect(.regular, in: shape)
            case .clear:
                self.glassEffect(.clear, in: shape)
            }
        } else {
            switch style {
            case .interactive, .regular:
                // Approximate the translucent glass with a frosted material clipped to the same shape.
                // Drawn as a background so it never changes the view's layout (same as glassEffect).
                self.background(.ultraThinMaterial, in: shape)
            case .clear:
                // `.clear` glass is intentionally invisible, so there is nothing to approximate.
                self
            }
        }
    }
}
