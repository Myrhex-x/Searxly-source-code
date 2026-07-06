//
//  AddressBarSuggestionsView.swift
//  Searxly
//
//  Glass dropdown panel for address-bar suggestions (sites + search queries).
//

import SwiftUI

struct AddressBarSuggestionsView: View {
    let suggestions: [AddressSuggestion]
    let selectedIndex: Int
    let isLoading: Bool
    let glassEnabled: Bool
    let toolbarMaterial: Material
    let barCornerRadius: CGFloat
    let maxWidth: CGFloat

    let onSelect: (AddressSuggestion) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var effectiveCorner: CGFloat {
        max(8, barCornerRadius - 2)
    }

    private var panelMaterial: Material {
        glassEnabled ? .ultraThinMaterial : toolbarMaterial
    }

    var body: some View {
        VStack(spacing: 0) {
            if suggestions.isEmpty && !isLoading {
                Text("No suggestions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    if shouldShowSectionHeader(at: index) {
                        sectionHeader(for: suggestion)
                    }

                    SuggestionRowView(
                        suggestion: suggestion,
                        isSelected: index == selectedIndex,
                        glassEnabled: glassEnabled,
                        position: rowPosition(at: index),
                        panelCornerRadius: effectiveCorner,
                        onSelect: { onSelect(suggestion) }
                    )
                }

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding suggestions…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(panelBackground)
        .searxlyGlass(
            glassEnabled ? .interactive : .clear,
            in: RoundedRectangle(cornerRadius: effectiveCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: effectiveCorner)
                .strokeBorder(
                    AdaptiveChrome.border(
                        colorScheme,
                        dark: glassEnabled ? 0.14 : 0.08,
                        light: glassEnabled ? 0.12 : 0.08
                    ),
                    lineWidth: 0.65
                )
        )
        .shadow(
            color: AdaptiveChrome.shadow(colorScheme, darkOpacity: glassEnabled ? 0.14 : 0.08),
            radius: glassEnabled ? 14 : 6,
            x: 0,
            y: 5
        )
        .frame(maxWidth: maxWidth, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: effectiveCorner, style: .continuous)
            .fill(panelMaterial)
            .background {
                RoundedRectangle(cornerRadius: effectiveCorner, style: .continuous)
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.018, light: 0.012))
            }
    }

    private func rowPosition(at index: Int) -> SuggestionRowPosition {
        let isFirst = index == 0
        let isLast = index == suggestions.count - 1 && !isLoading
        if isFirst && isLast { return .only }
        if isFirst { return .first }
        if isLast { return .last }
        return .middle
    }

    private func shouldShowSectionHeader(at index: Int) -> Bool {
        guard index > 0, index < suggestions.count else { return false }
        return suggestions[index].action != suggestions[index - 1].action
    }

    @ViewBuilder
    private func sectionHeader(for suggestion: AddressSuggestion) -> some View {
        Text(suggestion.action == .navigateURL ? "Sites" : "Searches")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}