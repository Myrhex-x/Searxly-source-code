//
//  TabSwitcherView.swift
//  SearxlyiOS
//
//  Safari-style tab overview: a two-column grid of live page snapshots. Tap to switch, ✕ or
//  flick a card upward to close, long-press for tab actions. Presented as a sheet.
//

import SwiftUI

struct TabSwitcherView: View {
    @Bindable var tabs: TabsModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    /// Search filters by page title, host, or search query (Safari's tab search).
    private var visibleTabs: [BrowserModel] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tabs.tabs }
        return tabs.tabs.filter { tab in
            tab.pageTitle.lowercased().contains(q)
                || (tab.webView.url?.host?.lowercased().contains(q) ?? false)
                || tab.searchQuery.lowercased().contains(q)
        }
    }

    /// Private cards stay hidden behind Face ID when the lock setting is on.
    private var privateLocked: Bool { tabs.privateTabsLocked }

    var body: some View {
        NavigationStack {
            ScrollView {
                if privateLocked {
                    privateLockBanner
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(visibleTabs) { tab in
                        let locked = privateLocked && tab.isPrivate
                        TabCard(
                            tab: tab,
                            isActive: tab.id == tabs.activeID,
                            locked: locked,
                            onSelect: {
                                if locked {
                                    Task { await tabs.revealPrivateTabs() }
                                } else {
                                    tabs.activate(tab)
                                    dismiss()
                                }
                            },
                            onClose: { close(tab) },
                            onCloseOthers: { withAnimation(.smooth) { tabs.closeOthers(keeping: tab) } }
                        )
                    }
                }
                .padding(14)
                .animation(.smooth(duration: 0.25), value: tabs.tabs.count)
                .animation(.smooth(duration: 0.25), value: privateLocked)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("\(tabs.tabs.count) Tab\(tabs.tabs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: Text(L("Search Tabs")))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                        .foregroundStyle(Brand.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            tabs.newTab()
                            dismiss()
                        } label: {
                            Label(L("New Tab"), systemImage: "plus.square")
                        }
                        Button {
                            tabs.newTab(isPrivate: true)
                            dismiss()
                        } label: {
                            Label(L("New Private Tab"), systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        tabs.newTab()
                        dismiss()
                    }
                    .foregroundStyle(Brand.text)
                    .accessibilityLabel("New tab")
                }
                if tabs.tabs.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button(L("Close All Tabs"), role: .destructive) {
                            withAnimation(.smooth) { tabs.closeAll() }
                        }
                    }
                }
            }
            .tint(Brand.text)
        }
    }

    private func close(_ tab: BrowserModel) {
        Haptics.tap()
        withAnimation(.smooth(duration: 0.25)) { tabs.close(tab) }
    }

    private var privateLockBanner: some View {
        Button { Task { await tabs.revealPrivateTabs() } } label: {
            HStack(spacing: 9) {
                Image(systemName: "hand.raised.fill").scaledFont(size: 13, weight: .semibold)
                Text(L("Private tabs are locked"))
                    .scaledFont(size: 14, weight: .medium)
                Spacer()
                Text(L("Unlock")).scaledFont(size: 13, weight: .semibold)
                Image(systemName: "faceid").scaledFont(size: 14)
            }
            .foregroundStyle(Brand.text)
            .padding(.horizontal, 15).padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 0.5))
            .padding(.horizontal, 14).padding(.top, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card

private struct TabCard: View {
    let tab: BrowserModel
    let isActive: Bool
    var locked: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    /// Flick-up-to-close: the card follows the finger (upward only) and closes past the threshold.
    @State private var dragY: CGFloat = 0

    var body: some View {
        VStack(spacing: 7) {
            preview
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    // Locked private tab: hide the snapshot behind a frosted lock cover.
                    if locked {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            Image(systemName: "lock.fill")
                                .scaledFont(size: 22, weight: .medium)
                                .foregroundStyle(Brand.textSecondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isActive ? Brand.text : Brand.hairline,
                                      lineWidth: isActive ? 2 : 0.5)
                )
                .overlay(alignment: .topTrailing) { if !locked { closeBadge } }

            HStack(spacing: 6) {
                icon
                if tab.isPrivate {
                    Image(systemName: "hand.raised.fill")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(Brand.textTertiary)
                        .accessibilityLabel("Private tab")
                }
                Text(locked ? L("Private Tab") : title)
                    .scaledFont(size: 12.5, weight: .medium)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .offset(y: dragY)
        .opacity(dragY < 0 ? Double(max(0.25, 1 + dragY / 260)) : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(flickToClose)
        .contextMenu {
            Button(action: onSelect) { Label(L("Switch to Tab"), systemImage: "square.on.square") }
            Divider()
            Button(role: .destructive, action: onClose) { Label(L("Close Tab"), systemImage: "xmark") }
            Button(role: .destructive, action: onCloseOthers) {
                Label(L("Close Other Tabs"), systemImage: "xmark.square")
            }
        }
        .accessibilityLabel("Tab: \(title)")
    }

    private var flickToClose: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Follow upward drags only; ignore sideways/downward (those are grid scrolls).
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragY = min(0, value.translation.height)
            }
            .onEnded { value in
                if dragY < -90 || (dragY < -40 && value.predictedEndTranslation.height < -220) {
                    onClose()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragY = 0 }
                }
            }
    }

    @ViewBuilder private var preview: some View {
        if case .web = tab.content, let snap = tab.snapshot {
            Image(uiImage: snap)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Brand.surface
                Image(systemName: placeholderGlyph)
                    .scaledFont(size: 26, weight: .light)
                    .foregroundStyle(Brand.textTertiary)
            }
        }
    }

    private var closeBadge: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(Brand.text)
                .frame(width: 24, height: 24)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Close tab")
    }

    @ViewBuilder private var icon: some View {
        switch tab.content {
        case .web:
            FaviconView(host: tab.webView.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "",
                        size: 16)
        case .home:
            Image(systemName: "house")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Brand.textTertiary)
        case .results:
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Brand.textTertiary)
        }
    }

    private var placeholderGlyph: String {
        switch tab.content {
        case .home: "house"
        case .results: "magnifyingglass"
        case .web: "globe"
        }
    }

    private var title: String {
        switch tab.content {
        case .home:    "New Tab"
        case .results: tab.searchQuery.isEmpty ? "Search" : tab.searchQuery
        case .web:     tab.pageTitle.isEmpty ? (tab.webView.url?.host ?? "Untitled") : tab.pageTitle
        }
    }
}
