//
//  LocalPackPromptView.swift
//  Searxly
//
//  The opt-in prompt shown at the top of results when a place query is detected but the local pack is
//  off. It explains the privacy trade-off — place data stays private through the gateway, but the map is
//  drawn by Apple — and lets the user enable it inline. Never shown in Maximum Privacy.
//

import SwiftUI

struct LocalPackPromptView: View {
    let categoryLabel: String
    let area: String?
    let useLocation: Bool
    let onEnable: () -> Void
    let onDismiss: () -> Void

    private var whereText: String {
        if useLocation || area == nil {
            return Localization.string("local_pack_near_you", defaultValue: "near you")
        }
        return String(format: Localization.string("local_pack_near_place", defaultValue: "near %@"), (area ?? "").capitalized)
    }

    private var bodyText: String {
        if useLocation {
            return Localization.string(
                "local_pack_prompt_body_location",
                defaultValue: "Uses your Mac’s location once to show nearby places on a map. The place info is fetched privately through Searxly, but the map itself is drawn by Apple Maps — so Apple would see the map area. Your search query stays private, and you can turn this off anytime in Settings."
            )
        }
        return Localization.string(
            "local_pack_prompt_body",
            defaultValue: "Adds a map with nearby places at the top of results. The place info is fetched privately through Searxly, but the map itself is drawn by Apple Maps — so Apple would see the map area you view. Your search query stays private, and you can turn this off anytime in Settings."
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(String(
                    format: Localization.string("local_pack_prompt_title", defaultValue: "Show %@ %@ on a map?"),
                    categoryLabel.lowercased(), whereText
                ))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                Spacer(minLength: 4)
            }

            Text(bodyText)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: onEnable) {
                    Text(Localization.string("local_pack_prompt_enable", defaultValue: "Show map"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.primary, in: Capsule())
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text(Localization.string("local_pack_prompt_dismiss", defaultValue: "Not now"))
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: SERPDesign.maxListWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .searxlyFloatingPanel()
    }
}

/// Shown in the local-pack slot while places resolve (OSM can take a few seconds), so the wait reads as
/// progress rather than nothing happening.
struct LocalPackLoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(Localization.string("local_pack_loading", defaultValue: "Finding nearby places…"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: SERPDesign.maxListWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .searxlyFloatingPanel()
    }
}
