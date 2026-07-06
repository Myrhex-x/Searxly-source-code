//
//  SearxlyWalletBadge.swift
//  Searxly
//
//  The wallet's identity mark. There is ONE wallet glyph — `WalletBillfoldMark` — used
//  identically in the sidebar, Settings, and every wallet panel/sheet header. `SearxlyWalletBadge`
//  simply frames that same glyph in a premium monochrome tile for the wallet's own chrome.
//  Black & white only — no accent color, no blue-tinted material.
//

import SwiftUI

/// The wallet glyph framed in a premium monochrome tile (used by the wallet's panel / sheet
/// headers). The glyph itself is identical to the bare mark shown in the sidebar and Settings.
struct SearxlyWalletBadge: View {
    var size: CGFloat = 22
    var cornerRadius: CGFloat = 6
    /// Kept for call-site compatibility; the badge is intentionally a controlled dark tile
    /// (not system material) so it stays pure black-and-white regardless of what's behind it.
    var glassEnabled: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(WalletTheme.surfaceStrong)
                .overlay(
                    // A faint top-down sheen reads as "premium glass" without any color tint.
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                )
                .overlay(shape.strokeBorder(WalletTheme.hairlineStrong, lineWidth: 0.8))
                .frame(width: size, height: size)

            WalletBillfoldMark(color: WalletTheme.textPrimary)
                .frame(width: size * 0.58, height: size * 0.58)
        }
    }
}

/// THE wallet icon: a clean billfold — rounded body, a flap seam across the upper third, and a
/// snap clasp. Monochrome and crisp from ~14pt up. Renders in whatever `color` is passed so the
/// sidebar (secondary), Settings (secondary), and badges (white) all share one glyph.
struct WalletBillfoldMark: View {
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let stroke = max(w * 0.085, 1)

            // Wallet body — a rounded rectangle, slightly wider than tall.
            let body = CGRect(x: w * 0.13, y: h * 0.26, width: w * 0.74, height: h * 0.50)
            let bodyPath = Path(roundedRect: body, cornerRadius: w * 0.18)
            ctx.stroke(bodyPath, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke, lineJoin: .round))

            // Flap seam across the upper third.
            var flap = Path()
            flap.move(to: CGPoint(x: body.minX, y: h * 0.435))
            flap.addLine(to: CGPoint(x: body.maxX, y: h * 0.435))
            ctx.stroke(flap, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke * 0.82, lineCap: .round))

            // Snap clasp on the right, centered in the lower band.
            let r = w * 0.072
            let cx = body.maxX - w * 0.10
            let cy = h * 0.605
            let clasp = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: clasp), with: .color(color))
        }
    }
}

/// The Searxly hexagon mark: an outlined flat-top hexagon with a small filled core.
struct SearxlyHexMark: View {
    var color: Color = .primary
    var lineWidthRatio: CGFloat = 0.13

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let cx = w / 2, cy = h / 2
            let r = min(w, h) / 2

            var hex = Path()
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 6
                let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                if i == 0 { hex.move(to: pt) } else { hex.addLine(to: pt) }
            }
            hex.closeSubpath()
            ctx.stroke(hex, with: .color(color),
                       style: StrokeStyle(lineWidth: w * lineWidthRatio, lineCap: .round, lineJoin: .round))

            // Filled core
            let innerR = r * 0.30
            var inner = Path()
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 6
                let pt = CGPoint(x: cx + innerR * cos(angle), y: cy + innerR * sin(angle))
                if i == 0 { inner.move(to: pt) } else { inner.addLine(to: pt) }
            }
            inner.closeSubpath()
            ctx.fill(inner, with: .color(color))
        }
    }
}
