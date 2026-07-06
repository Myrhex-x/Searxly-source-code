//
//  HomeStarfield.swift
//  Searxly
//
//  NOTE: The implementation has been inlined into ContentView.swift
//  (as a private struct) to avoid recurring "Cannot find in scope" issues
//  caused by Xcode target / FileSystemSynchronizedRootGroup membership.
//
//  This file is now intentionally empty of types so it does not cause
//  redeclaration errors. You can safely delete this file from the Xcode
//  project navigator (right-click → Delete → Move to Trash) if desired.
//
//  The actual starfield code (grok.com style) lives inside ContentView.swift
//  near the bottom of the file, guarded by the "homeStarsEnabled" setting.
//

import SwiftUI

struct HomeStarfield: View {
    /// Whether the feature is enabled (from Appearance settings).
    /// When false we render a very faint static field (or nothing if desired).
    let enabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var starColor: Color {
        // Light mode inverts to faint graphite specks — kept well below the dark-mode
        // intensity so they read as texture, not dust on the paper canvas.
        colorScheme == .dark ? .white : Color.primary.opacity(0.16)
    }

    var body: some View {
        let shouldAnimate = enabled && !reduceMotion

        if shouldAnimate {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    drawGrokStyleStars(context: &context, size: size, time: time)
                }
            }
            .allowsHitTesting(false)
            .opacity(1.0)
        } else {
            Canvas { context, size in
                drawStaticStars(context: &context, size: size)
            }
            .allowsHitTesting(false)
            .opacity(enabled ? 0.95 : 0.25)
        }
    }

    private func drawGrokStyleStars(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let targetCount = max(90, min(200, Int((size.width * size.height) / 1900) + 65))

        for i in 0..<targetCount {
            let seed = Double(i) * 0.9182 + 1.7
            let layer = i % 3
            let speed = (layer == 0) ? 0.0009 : (layer == 1 ? 0.00145 : 0.00055)

            var x = size.width * CGFloat(
                fmod(seed * 0.39 + time * speed * (1.0 + (seed.truncatingRemainder(dividingBy: 2.1) - 1.0) * 0.6), 1.0)
            )
            var y = size.height * CGFloat(
                fmod(seed * 0.71 + time * (speed * 0.72) * (1.0 + (seed.truncatingRemainder(dividingBy: 3.3) - 1.2) * 0.5), 1.0)
            )

            if x < 0 { x += size.width }
            if y < 0 { y += size.height }
            if x > size.width { x -= size.width }
            if y > size.height { y -= size.height }

            let twinkleFreq = 0.9 + seed.truncatingRemainder(dividingBy: 4.1)
            let twinkle = sin(time * twinkleFreq * 1.6) * 0.32 + 0.68
            let base = 0.14 + (seed * 0.47).truncatingRemainder(dividingBy: 0.095)
            let alpha = max(0.08, base * twinkle * 2.1)
            let sizeJitter = CGFloat((i * 17) % 7) * 0.07
            let s: CGFloat = (layer == 2 ? 0.9 : 1.35) + sizeJitter

            context.opacity = alpha
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(starColor))
        }

        for i in 0..<11 {
            let seed = Double(i + 400) * 1.137
            let x = size.width * CGFloat(fmod(seed * 0.27 + time * 0.0007, 1.0))
            let y = size.height * CGFloat(fmod(seed * 0.63 + time * 0.0004, 1.0))
            let tw = sin(time * (1.1 + seed.truncatingRemainder(dividingBy: 2.7)) * 2.1) * 0.4 + 0.6
            let a = 0.26 * tw
            context.opacity = a
            let s: CGFloat = 1.8 + CGFloat(i % 3) * 0.35
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(starColor))
        }
        context.opacity = 1.0
    }

    private func drawStaticStars(context: inout GraphicsContext, size: CGSize) {
        let count = max(90, min(200, Int((size.width * size.height) / 2000) + 70))
        for i in 0..<count {
            let seed = Double(i) * 0.871 + 0.4
            let x = size.width * CGFloat((i * 53 + 7) % 97) / 100.0
            let y = size.height * CGFloat((i * 29 + 19) % 91) / 100.0
            let s: CGFloat = 0.75 + CGFloat((i * 11) % 5) * 0.18
            let alpha = 0.12 + (seed * 0.6).truncatingRemainder(dividingBy: 0.07)
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(starColor.opacity(alpha / 0.5)))
        }
    }
}
