//
//  AppleIntelligenceMark.swift
//  SearxlyiOS
//
//  Official SF Symbol for Apple Intelligence (`apple.intelligence`) — the multicolor Siri-style
//  mark Apple ships for features that run on Foundation Models / Apple Intelligence. Only use
//  this when the feature truly is Apple Intelligence on-device (which ours is).
//

import SwiftUI

/// Official Apple Intelligence glyph (SF Symbol `apple.intelligence`, multicolor).
struct AppleIntelligenceMark: View {
    var size: CGFloat = 28
    var monochrome: Bool = false

    var body: some View {
        Image(systemName: "apple.intelligence")
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(monochrome ? .hierarchical : .multicolor)
            .accessibilityLabel(L("Apple Intelligence"))
    }
}

/// Compact badge used in SERP / sheets: multicolor AI mark on a quiet chip.
struct AppleIntelligenceBadge: View {
    var iconSize: CGFloat = 11
    var diameter: CGFloat = 21

    var body: some View {
        Image(systemName: "apple.intelligence")
            .font(.system(size: iconSize, weight: .semibold))
            .symbolRenderingMode(.multicolor)
            .frame(width: diameter, height: diameter)
            .background(Brand.surfaceHi.opacity(0.9), in: Circle())
            .accessibilityHidden(true)
    }
}
