//
//  FaviconView.swift
//  SearxlyiOS
//
//  A site icon: the locally-cached real favicon when we have one (captured on visit — see
//  FaviconStore's privacy rule), otherwise the monochrome host-initial chip. Same footprint as
//  HostChip so it drops into result rows, suggestions, the library, and the tab switcher.
//

import SwiftUI

struct FaviconView: View {
    let host: String
    var size: CGFloat = 30
    /// SERP rows set this so missing icons are fetched from the host's well-known paths
    /// (see FaviconStore.ensureResultIcon — gated by the "Site Icons in Results" setting).
    var fetchIfMissing = false

    private var radius: CGFloat { size * 7 / 30 }

    var body: some View {
        content.task(id: host) {
            if fetchIfMissing, FaviconStore.shared.image(for: host) == nil {
                await FaviconStore.shared.ensureResultIcon(forHost: host)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let icon = FaviconStore.shared.image(for: host) {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .padding(size * 0.13) // icons breathe inside the chip instead of touching its edges
                .frame(width: size, height: size)
                // Always a light chip (Safari-style): favicons are drawn for light backgrounds,
                // and dark glyphs (github.blog…) vanish on a dark surface.
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Brand.hairline, lineWidth: 0.5)
                )
        } else {
            HostChip(host: host, size: size)
        }
    }
}
