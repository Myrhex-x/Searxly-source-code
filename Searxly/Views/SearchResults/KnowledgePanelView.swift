//
//  KnowledgePanelView.swift
//  Searxly
//
//  Tall, content-rich SERP knowledge panel. Fills vertical space beside results.
//

import SwiftUI

struct KnowledgePanelView: View {
    @Environment(\.colorScheme) private var colorScheme

    let content: KnowledgePanelContent
    let proxyBase: String?
    let minHeight: CGFloat
    let glassEnabled: Bool
    let onOpenURL: (String) -> Void

    @State private var showContributionSheet = false

    var body: some View {
        Group {
            if case .entity(let data) = content.kind {
                entityPanel(data)
            }
        }
        .frame(minHeight: minHeight, alignment: .top)
        // Same chrome as the floating tab sidebar (SearxlyFloatingPanel.swift): solid VPN-popover
        // canvas, 18pt continuous corners, sheen + rim light + layered shadow — one shared look.
        .searxlyFloatingPanel()
        .sheet(isPresented: $showContributionSheet) {
            KnowledgePanelContributionSheet(content: content)
        }
    }

    // MARK: - Entity

    @ViewBuilder
    private func entityPanel(_ data: EntityPanelData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            entityBanner(data)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            panelDivider
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 16) {
                entityTitleBlock(data)
                aboutSection(data.aboutParagraphs)

                if !data.facts.isEmpty {
                    factsSection(data.facts)
                }

                actionSection(data)
                contributionButton
                grokipediaAttribution
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private func entityBanner(_ data: EntityPanelData) -> some View {
        if !data.bannerImageCandidates.isEmpty {
            bannerImage(candidates: data.bannerImageCandidates, referer: data.bannerImageReferer)
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        AdaptiveChrome.fill(colorScheme, dark: 0.08),
                        AdaptiveChrome.fill(colorScheme, dark: 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                entityMonogram(title: data.title, kind: data.entityKind, compact: true)
            }
            .frame(height: 128)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func bannerImage(candidates: [URL], referer: String?) -> some View {
        CachedSearchThumbnail(
            candidates: candidates,
            referer: referer,
            aspectRatio: 16.0 / 9.0,
            fillFrameHeight: 128
        )
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func entityTitleBlock(_ data: EntityPanelData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // No kind chips — the title and its source link carry enough context, and chips added
            // visual noise (and risked mislabelling). Only the plain source-host caption remains.
            if let label = data.officialSiteLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func aboutSection(_ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("About")

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.78))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func factsSection(_ facts: [KnowledgeFact]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Details")

            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    HStack(alignment: .top, spacing: 10) {
                        Text(fact.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 84, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(fact.value)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.88 : 0.84))
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)

                    if index < facts.count - 1 {
                        insetDivider
                    }
                }
            }
            .background(insetSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func actionSection(_ data: EntityPanelData) -> some View {
        VStack(spacing: 6) {
            let isPerson = data.entityKind == .person
            let prefersOfficialPrimary = data.entityKind == .company
                || data.entityKind == .product
                || data.entityKind == .website
                || data.entityKind == .organization

            if prefersOfficialPrimary,
               let officialURL = data.officialSiteURL,
               let label = data.officialSiteLabel {
                actionRow(title: label, systemImage: "arrow.up.forward.square", url: officialURL, prominent: true)
            }

            if isPerson, let grokURL = data.grokipediaURL {
                actionRow(
                    title: "Learn more about \(data.title)",
                    systemImage: "book.closed",
                    url: grokURL,
                    prominent: true
                )
            } else if let grokURL = data.grokipediaURL {
                actionRow(
                    title: "Learn more about \(data.title)",
                    systemImage: "book.closed",
                    url: grokURL,
                    prominent: false
                )
            }

            if isPerson,
               let officialURL = data.officialSiteURL,
               let label = data.officialSiteLabel {
                actionRow(title: label, systemImage: "link", url: officialURL, prominent: false)
            }
        }
    }

    // MARK: - Chrome
    // The outer panel surface is the shared floating-panel chrome (searxlyFloatingPanel) — the
    // same material as the floating tab sidebar. Only the inner inset cards are styled here.

    private var insetSurface: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AdaptiveChrome.fill(colorScheme, dark: colorScheme == .dark ? 0.05 : 0.035))
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(AdaptiveChrome.divider(colorScheme))
            .frame(height: 1)
    }

    private var insetDivider: some View {
        Rectangle()
            .fill(AdaptiveChrome.divider(colorScheme))
            .frame(height: 1)
            .padding(.horizontal, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var contributionButton: some View {
        Button {
            showContributionSheet = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AdaptiveChrome.fill(colorScheme, dark: 0.07))
                        .frame(width: 32, height: 32)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Improve this panel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.92))
                    Text("Report an error or suggest a change")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(insetSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.09), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var grokipediaAttribution: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed")
                .font(.caption2)
            Text("Grokipedia")
                .font(.caption2)
        }
        .foregroundStyle(.quaternary)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func actionRowBackground(prominent: Bool) -> some View {
        if prominent {
            insetSurface
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.03))
        }
    }

    private func actionRow(title: String, systemImage: String, url: String, prominent: Bool) -> some View {
        Button {
            onOpenURL(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(prominent ? Color.primary.opacity(0.9) : Color.secondary)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: prominent ? 13 : 12, weight: prominent ? .medium : .regular))
                    .foregroundStyle(prominent ? Color.primary.opacity(0.92) : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, prominent ? 10 : 9)
            .background(actionRowBackground(prominent: prominent))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        AdaptiveChrome.border(colorScheme, dark: prominent ? 0.1 : 0.07),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func entityMonogram(
        title: String,
        kind: OfficialEntityDatabase.EntityKind?,
        compact: Bool = false
    ) -> some View {
        let letter = title.first.map { String($0).uppercased() } ?? "?"
        return VStack(spacing: 4) {
            Text(letter)
                .font(.system(size: compact ? 40 : 32, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
            if let kind {
                Image(systemName: kindIcon(kind))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func kindIcon(_ kind: OfficialEntityDatabase.EntityKind) -> String {
        switch kind {
        case .company: return "building.2"
        case .person: return "person.crop.circle"
        case .organization: return "person.3"
        case .product: return "cube"
        case .place: return "mappin.and.ellipse"
        case .website: return "globe"
        }
    }
}

struct KnowledgePanelLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme

    var minHeight: CGFloat = SERPDesign.knowledgePanelMinContentHeight
    var glassEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06))
                .frame(height: 128)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Rectangle()
                .fill(AdaptiveChrome.divider(colorScheme))
                .frame(height: 1)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.08))
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06))
                    .frame(height: 13)
                    .frame(maxWidth: 120)

                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AdaptiveChrome.fill(colorScheme, dark: 0.045))
                        .frame(height: 12)
                }

                Spacer(minLength: 8)

                ProgressView()
                    .scaleEffect(0.85)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(minHeight: minHeight, alignment: .top)
        .background(loadingSurface)
        .clipShape(RoundedRectangle(cornerRadius: SERPDesign.knowledgePanelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SERPDesign.knowledgePanelCornerRadius, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.12 : 0.08), lineWidth: 0.6)
        )
    }

    private var loadingSurface: some View {
        ZStack {
            if colorScheme == .dark {
                AdaptiveChrome.canvasDark.opacity(glassEnabled ? 0.92 : 0.98)
            }
            RoundedRectangle(cornerRadius: SERPDesign.knowledgePanelCornerRadius, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.045))
            if glassEnabled {
                RoundedRectangle(cornerRadius: SERPDesign.knowledgePanelCornerRadius, style: .continuous)
                    .fill(.thinMaterial)
                    .opacity(colorScheme == .dark ? 0.35 : 0.5)
            }
        }
    }
}