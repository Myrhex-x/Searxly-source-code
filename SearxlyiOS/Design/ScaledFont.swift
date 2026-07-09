//
//  ScaledFont.swift
//  SearxlyiOS
//
//  Dynamic Type for the app's fixed-size system fonts. Searxly styles text with explicit point sizes
//  (`.system(size:)`), which on their own ignore the user's text-size setting entirely. `.scaledFont`
//  is a drop-in replacement that wraps the size in an @ScaledMetric, so the same designs scale up and
//  down with Dynamic Type — and live-update the moment the setting changes — without redesigning views.
//

import SwiftUI

private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo textStyle: Font.TextStyle) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:design:))` that scales with Dynamic Type.
    /// `relativeTo` chooses which text style the size tracks (default `.body`).
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo textStyle: Font.TextStyle = .body) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, relativeTo: textStyle))
    }
}
