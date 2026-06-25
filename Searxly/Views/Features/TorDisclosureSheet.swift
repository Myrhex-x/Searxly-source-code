//
//  TorDisclosureSheet.swift
//  Searxly
//
//  One-time consent shown before the user's first .onion connection. Sets honest expectations about
//  what Tor routing protects — and what it doesn't — so nobody bets their safety on a false sense of
//  anonymity. Monochrome, per brand.
//

import SwiftUI

struct TorDisclosureSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 21, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browsing over Tor")
                        .font(.system(size: 17, weight: .bold))
                    Text("Before you open your first .onion site")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                row(icon: "checkmark.shield.fill",
                    title: "What this protects",
                    detail: "Your real IP is hidden — onion tabs are routed through the Tor network across multiple relays, and .onion hidden services become reachable with no DNS leaks.")

                row(icon: "exclamationmark.triangle.fill",
                    title: "What it does NOT do",
                    detail: "This is not Tor Browser. It doesn’t provide Tor Browser’s full anti-fingerprinting, so a determined site may still be able to fingerprint your browser. For maximum anonymity, use the official Tor Browser.")

                row(icon: "person.crop.circle.badge.xmark",
                    title: "Stay anonymous",
                    detail: "Don’t sign in to personal or clearnet accounts in an onion tab — that links your identity to your activity. Be mindful of what you access; some onion content is illegal or harmful.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: onContinue) {
                    Text("Continue")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
