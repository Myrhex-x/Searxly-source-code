//
//  MediaPreviewSheet.swift
//  Searxly
//
//  Premium lightbox/preview for both images and videos.
//
//  Redesigned to the Searxly floating-panel language: a translucent liquid-glass card (the same
//  material family as the floating tab sidebar / knowledge panel) that floats over a transparent
//  sheet — super-round continuous corners, a rim-light border, a faint top sheen, and a layered
//  shadow. Strictly monochrome per brand: the media floats on the glass, chrome is neutral, and the
//  single emphasized action is a high-contrast INK pill (no decorative green). Threaded proxyBaseURL
//  still fetches the high-quality full-size preview via the user's SearXNG instance.
//

import SwiftUI
import os
import AppKit

struct MediaPreviewSheet: View {
    let result: SearXNGResult
    let isVideo: Bool
    let onOpenPage: () -> Void
    let proxyBaseURL: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("reduceLiquidGlass") private var reduceLiquidGlass = false
    private var glassEnabled: Bool { !reduceLiquidGlass }

    @State private var didCopy = false
    @State private var isOpenHovered = false

    private var previewCandidates: [URL] {
        SearchMediaURLResolver.candidateURLs(for: result, proxyBase: proxyBaseURL, mode: .fullSizePreview)
    }

    private var hostLabel: String? {
        guard let host = URL(string: result.url)?.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// Inverted label color for the monochrome ink primary button (black text on the white pill in
    /// dark mode, white text on the black pill in light mode).
    private var inkLabelColor: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        VStack(spacing: 0) {
            header
            imageStage
            footer
        }
        .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity,
               minHeight: 500, idealHeight: 680, maxHeight: .infinity)
        .modifier(FloatingGlassCard(cornerRadius: 24, glassEnabled: glassEnabled, scheme: colorScheme))
        .padding(14)
        .presentationBackground(.clear)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title.isEmpty ? (hostLabel ?? "Preview") : result.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let hostLabel {
                    HStack(spacing: 5) {
                        FaviconView(pageURL: result.url, size: 12, cornerRadius: 3, loadRemote: true)
                        Text(hostLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .glassIcon(size: 30, glassEnabled: glassEnabled)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Image / video stage

    private var imageStage: some View {
        ZStack {
            if !previewCandidates.isEmpty {
                // Dev diagnostic (when you open preview from a blank grid tile under "Images"/"Videos").
                let _ = {
                    if DeveloperSettings.shared.isEnabled, let u = previewCandidates.first {
                        Log.app.info("[Dev][MediaPreview] previewURL=\(u.absoluteString.prefix(110)) isVideo=\(isVideo)")
                    }
                }()

                CachedSearchThumbnail(
                    candidates: previewCandidates,
                    referer: result.url,
                    aspectRatio: isVideo ? 16.0 / 9.0 : 4.0 / 3.0,
                    contentMode: .fit,
                    useNaturalAspect: true,
                    naturalMaxHeight: 560
                )
                // The media floats on the glass with its own soft shadow — no heavy black stage.
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.20), radius: 24, x: 0, y: 12)
                .overlay {
                    if isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.95))
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: isVideo ? "video.slash" : "photo")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(isVideo ? "No video thumbnail available" : "No image available for preview")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .padding(60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer (meta + actions)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            metaRow
            actionRow
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var metaRow: some View {
        HStack(spacing: 7) {
            if let res = result.resolution, !res.isEmpty {
                metaChip(res, systemImage: "square.dashed")
            }
            if let format = result.img_format, !format.isEmpty {
                metaChip(format.uppercased(), systemImage: "doc")
            }
            if let eng = result.enginesDisplay ?? result.primaryEngine {
                metaChip(eng, systemImage: "magnifyingglass")
            }
            if let pub = result.formattedPublishedDate() {
                metaChip(pub, systemImage: "calendar")
            }

            Spacer(minLength: 8)

            Text(result.url)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 210, alignment: .trailing)
        }
    }

    private func metaChip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.05))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.5)
                )
        )
        .fixedSize()
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            // Primary — monochrome INK pill (replaces the off-brand green prominent button).
            Button {
                onOpenPage()
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Open page")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(inkLabelColor)
                .padding(.horizontal, 15)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isOpenHovered ? 0.88 : 1.0))
                )
                .scaleEffect(isOpenHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .onHover { hovering in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isOpenHovered = hovering }
            }
            .help("Visit the original page for this image")

            // Secondary — glass pill (the same material as the sidebar's New Tab pill).
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.url, forType: .string)
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopy = false }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    Text(didCopy ? "Copied" : Localization.string("search_result_copy_page_url"))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .glassPill(glassEnabled: glassEnabled)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Floating glass card

/// The lightbox surface: a translucent liquid-glass card in the Searxly floating-panel language —
/// real Liquid Glass on macOS 26+ (frosted material fallback below), a rim-light border, a faint top
/// sheen, and a layered shadow so it lifts off the transparent sheet. Monochrome by brand.
private struct FloatingGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let glassEnabled: Bool
    let scheme: ColorScheme

    private var isDark: Bool { scheme == .dark }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    /// A faint tint that keeps chrome text legible over whatever shows through the glass, without
    /// killing the translucency.
    private var tint: Color {
        AdaptiveChrome.dynamic(
            light: Color.white.opacity(0.5),
            dark: Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.55)
        )
    }

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .background(
                shape.fill(tint)
                    .background(shape.fill(.ultraThinMaterial).opacity(glassEnabled ? 0.7 : 0.95))
                    .searxlyGlass(glassEnabled ? .regular : .clear, in: shape)
            )
            // Faint top-down sheen — premium-glass cue, never a color.
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(isDark ? 0.06 : 0.12), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)
                ))
                .allowsHitTesting(false)
            )
            // Rim light: brighter along the top edge where the sheen hits — the edge of real glass.
            .overlay(shape.strokeBorder(
                LinearGradient(
                    colors: [
                        AdaptiveChrome.dynamic(light: Color.black.opacity(0.12), dark: Color.white.opacity(0.24)),
                        AdaptiveChrome.dynamic(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08)),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            ))
            .shadow(color: .black.opacity(isDark ? 0.34 : 0.12), radius: 4, y: 2)
            .shadow(color: .black.opacity(isDark ? 0.5 : 0.18), radius: 30, y: 16)
    }
}
