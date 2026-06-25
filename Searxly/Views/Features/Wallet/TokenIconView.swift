//
//  TokenIconView.swift
//  Searxly
//
//  Reusable token icon: ETH diamond, SEARXLY hexagon, generic letter+color for custom ERC-20s.
//

import SwiftUI

struct TokenIconView: View {
    let token: WalletToken
    var size: CGFloat = 40

    @State private var directory = WalletTokenDirectory.shared

    var body: some View {
        ZStack {
            // Always-present tinted backing, so a transparent or dark logo never disappears against
            // the near-black canvas (it shows through the logo's transparent areas).
            Circle().fill(token.iconColor)

            if let url = logoURL {
                // Real coin logo (CoinGecko CDN, keyed only by the public contract). The drawn glyph
                // shows while it loads and stays as the fallback if the image can't be fetched.
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).scaledToFill()
                    } else {
                        tokenGlyph
                    }
                }
            } else {
                tokenGlyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        .task(id: token.aggregatedID) {
            await directory.ensureLogo(chainId: token.chainId, contract: token.contractAddress)
        }
    }

    /// The real-logo URL for this token, or nil to fall back to the drawn mark. Every ERC-20 (incl.
    /// SEARXLY, which is a listed token) uses its real logo from the directory; the native gas coins use
    /// a known logo. The drawn glyph only shows while loading or for a coin no list knows.
    private var logoURL: URL? {
        // Core coins get a known, verified logo immediately — so a wrapped/native coin (ETH, WETH, POL)
        // never falls back to a generic glyph while the token list resolves.
        switch token.symbol.uppercased() {
        case "ETH":
            return URL(string: "https://assets.coingecko.com/coins/images/279/large/ethereum.png")
        case "WETH":
            return URL(string: "https://assets.coingecko.com/coins/images/39810/large/weth.png")
        case "POL", "MATIC":
            return URL(string: "https://assets.coingecko.com/coins/images/4713/large/polygon.png")
        default:
            break
        }
        if let contract = token.contractAddress {
            // Real logo: the CoinGecko list (crisp /large/ variant), or the DexScreener fallback once
            // it resolves. Both handled by the directory.
            return directory.resolvedLogo(chainId: token.chainId, contract: contract).flatMap { URL(string: $0) }
        }
        return nil
    }

    @ViewBuilder
    private var tokenGlyph: some View {
        switch token.symbol.uppercased() {
        case "ETH", "WETH":
            EthDiamond(size: size * 0.54)
        case "SEARXLY":
            SearxlyHex(size: size * 0.58)
        case "WBTC", "CBBTC", "BTC":
            Text("₿")
                .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        default:
            if token.isStablecoin {
                Text("$")
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Text(String(token.symbol.prefix(1)))
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - ETH Diamond

private struct EthDiamond: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height, cx = w / 2

            // Canonical Ethereum mark: a faceted octahedron, taller than wide.
            let sideX = w * 0.30           // horizontal half-width at the waist
            let topApex   = CGPoint(x: cx, y: 0)
            let leftWaist = CGPoint(x: cx - sideX, y: h * 0.34)
            let rightWaist = CGPoint(x: cx + sideX, y: h * 0.34)
            let center    = CGPoint(x: cx, y: h * 0.47)
            let botApex   = CGPoint(x: cx, y: h)

            func facet(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ shade: Double) {
                var p = Path()
                p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.closeSubpath()
                ctx.fill(p, with: .color(.white.opacity(shade)))
            }

            // Upper diamond: left facet (dim) + right facet (bright)
            facet(topApex, leftWaist, center, 0.78)
            facet(topApex, rightWaist, center, 1.0)
            // Lower triangle: left facet (dim) + right facet (bright)
            facet(leftWaist, center, botApex, 0.55)
            facet(rightWaist, center, botApex, 0.72)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - SEARXLY Hexagon

private struct SearxlyHex: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let cx = w / 2, cy = h / 2
            let r = min(w, h) / 2

            // Regular hexagon (flat-top orientation)
            var hex = Path()
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 6
                let x = cx + r * cos(angle)
                let y = cy + r * sin(angle)
                if i == 0 { hex.move(to: .init(x: x, y: y)) }
                else       { hex.addLine(to: .init(x: x, y: y)) }
            }
            hex.closeSubpath()
            ctx.stroke(hex, with: .color(.white), style: StrokeStyle(lineWidth: w * 0.12, lineCap: .round, lineJoin: .round))

            // Inner "S" dot / small filled hexagon
            let innerR = r * 0.32
            var inner = Path()
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 6
                let x = cx + innerR * cos(angle)
                let y = cy + innerR * sin(angle)
                if i == 0 { inner.move(to: .init(x: x, y: y)) }
                else       { inner.addLine(to: .init(x: x, y: y)) }
            }
            inner.closeSubpath()
            ctx.fill(inner, with: .color(.white))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Compact inline variant (for token selectors)

struct TokenIconDot: View {
    let token: WalletToken
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(token.iconColor)
            .frame(width: size, height: size)
    }
}
