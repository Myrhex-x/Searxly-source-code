//
//  CommandPaletteView.swift
//  Searxly
//
//  Spotlight-style ⌘K command palette: a centered, keyboard-driven floating panel that fuzzy-searches
//  open tabs, bookmarks, and history, and exposes quick actions. Gated by browserState.showingCommandPalette
//  and presented as an overlay in ContentView (see ContentView body).
//
//  Keyboard model: the search field holds focus; ↑/↓ move the selection (a single-line field ignores
//  vertical arrows so they reach our onKeyPress), ⏎ activates the selection (field onSubmit), Esc closes.
//

import SwiftUI

struct CommandPaletteView: View {
    @Bindable var browserState: BrowserState
    let glassEnabled: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private let panelWidth: CGFloat = 640

    private var results: [PaletteResult] {
        CommandPaletteBuilder.build(
            query: query,
            tabs: browserState.tabs,
            selectedTabID: browserState.selectedTabID,
            bookmarks: browserState.bookmarks,
            history: browserState.history,
            detectedURL: browserState.smartURL(from: query)
        )
    }

    var body: some View {
        if browserState.showingCommandPalette {
            ZStack(alignment: .top) {
                // Dimmed scrim — click outside to dismiss.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                panel
                    .frame(width: panelWidth)
                    .padding(.top, 96)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: browserState.showingCommandPalette)
            .onAppear { resetForPresentation() }
            // Esc closes. onExitCommand is the macOS-native Escape handler and fires even when the
            // focused text field would otherwise swallow the key; onKeyPress(.escape) is a backstop.
            .onExitCommand { close() }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.4)
            resultsList
        }
        .background(
            glassEnabled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(glassEnabled ? 0.24 : 0.16), radius: 30, x: 0, y: 14)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search tabs, bookmarks, history, or the web…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($fieldFocused)
                .onSubmit { activateSelected() }
                .onChange(of: query) { _, _ in selectedIndex = 0 }

            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var resultsList: some View {
        let items = results
        if items.isEmpty {
            HStack {
                Spacer()
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 28)
                Spacer()
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            CommandPaletteRow(
                                item: item,
                                isSelected: index == clampedSelection(items.count)
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { activate(item) }
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Selection + activation

    private func clampedSelection(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selectedIndex, 0), count - 1)
    }

    private func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = (clampedSelection(count) + delta + count) % count
    }

    private func activateSelected() {
        let items = results
        guard !items.isEmpty else { return }
        activate(items[clampedSelection(items.count)])
    }

    private func activate(_ item: PaletteResult) {
        browserState.activatePaletteResult(item.action)   // also flips showingCommandPalette = false
    }

    private func close() {
        browserState.showingCommandPalette = false
    }

    private func resetForPresentation() {
        query = ""
        selectedIndex = 0
        // Defer focus one tick so the field is in the hierarchy before we request focus.
        DispatchQueue.main.async { fieldFocused = true }
    }
}

// MARK: - Row

private struct CommandPaletteRow: View {
    let item: PaletteResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let badge = item.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
        )
    }
}
