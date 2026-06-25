//
//  SidebarTabList.swift
//  Searxly
//

import SwiftUI
import WebKit

struct SidebarTabList: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var tabs: [BrowserTab]
    @Binding var selectedTabID: UUID?

    @State private var hoveredTabID: UUID? = nil

    let glassEnabled: Bool
    let toolbarMaterial: Material
    let sidebarWidth: CGFloat
    let isCollapsed: Bool
    let toggleCollapse: () -> Void

    let newTabAction: () -> Void
    let newPrivateTabAction: () -> Void
    let closeTabAction: (BrowserTab) -> Void
    let closeAllTabsAction: () -> Void
    let moveTab: (Int, Int) -> Void
    let pinTabAction: (BrowserTab) -> Void
    let duplicateTabAction: (BrowserTab) -> Void
    let muteTabAction: (BrowserTab) -> Void
    let forgetDomainAction: (String) -> Void
    let reopenClosedTabAction: (() -> Void)?
    let hasClosedTabs: Bool

    @Binding var showingSettings: Bool
    @Binding var showingWallet: Bool
    @Binding var showingBookmarks: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingDownloads: Bool

    @State private var isSettingsHovered = false
    @State private var isWalletHovered = false
    @State private var isDownloadsHovered = false

    private var pinnedTabs: [BrowserTab] { tabs.filter { $0.isPinned } }
    private var regularTabs: [BrowserTab] { tabs.filter { !$0.isPinned } }
    /// Non-pinned normal tabs (everything that isn't a Tor / onion tab).
    private var normalTabs: [BrowserTab] { regularTabs.filter { $0.privacyMode != .onion } }
    /// Non-pinned onion (Tor) tabs — grouped under their own "Tor" section in the sidebar.
    private var onionTabs: [BrowserTab] { regularTabs.filter { $0.privacyMode == .onion } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topNavigationZone

            Group {
                if isCollapsed {
                    collapsedTabRail
                } else {
                    expandedTabList
                }
            }
            .frame(maxHeight: .infinity)

            if !isCollapsed {
                SidebarDeleteAllTabsButton(action: closeAllTabsAction)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                if TabHibernationManager.shared.isEnabled {
                    hibernationTimerIndicator
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }

            bottomFooter
            walletButton
            settingsButton
        }
        .background {
            Rectangle()
                .fill(AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled))
        }
    }

    // MARK: - Expanded tab list

    private var expandedTabList: some View {
        List {
            // Pinned group
            if !pinnedTabs.isEmpty {
                Section {
                    ForEach(pinnedTabs) { tab in
                        tabRow(tab)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.06))
                                    .padding(.horizontal, 4)
                            )
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                        Text("PINNED")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }

            // Normal (non-Tor) tabs. Header only when there's another group to separate from.
            if !normalTabs.isEmpty {
                if !pinnedTabs.isEmpty || !onionTabs.isEmpty {
                    Section { normalTabRows } header: { sidebarGroupHeader("TABS") }
                } else {
                    normalTabRows
                }
            }

            // Tor (onion) tabs — their own clearly separated group.
            if !onionTabs.isEmpty {
                Section {
                    ForEach(onionTabs) { tab in
                        tabRow(tab)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 9, weight: .bold))
                        Text("TOR")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var normalTabRows: some View {
        ForEach(normalTabs) { tab in
            tabRow(tab)
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .onMove { indices, newOffset in
            let pinnedCount = pinnedTabs.count
            guard let relFrom = indices.first else { return }
            let targetTab = normalTabs[relFrom]
            guard let absFrom = tabs.firstIndex(where: { $0.id == targetTab.id }) else { return }
            moveTab(absFrom, pinnedCount + newOffset)
        }
    }

    private func sidebarGroupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tabRow(_ tab: BrowserTab) -> some View {
        let isHib = TabHibernationManager.shared.isHibernated(tab)
        TabButton(
            tab: tab,
            isSelected: selectedTabID == tab.id,
            isHovered: hoveredTabID == tab.id,
            glassEnabled: glassEnabled,
            toolbarMaterial: toolbarMaterial,
            style: .sidebarCompact,
            onSelect: { selectedTabID = tab.id },
            onClose: {
                guard !tab.isPinned else { return }
                closeTabAction(tab)
            }
        )
        .opacity(isHib ? 0.55 : 1.0)
        .overlay(alignment: .trailing) {
            HStack(spacing: 4) {
                if tab.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .padding(.trailing, isHib ? 0 : 8)
                }
                if isHib {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
            }
        }
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : nil
        }
        .contextMenu { tabContextMenu(for: tab) }
    }

    // MARK: - Collapsed rail

    private var collapsedTabRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(pinnedTabs) { tab in
                    collapsedTabIcon(for: tab)
                }

                if !pinnedTabs.isEmpty && !regularTabs.isEmpty {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 20, height: 1.5)
                        .padding(.vertical, 1)
                }

                ForEach(regularTabs) { tab in
                    collapsedTabIcon(for: tab)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func collapsedTabIcon(for tab: BrowserTab) -> some View {
        let isSelected = selectedTabID == tab.id
        let isHib = TabHibernationManager.shared.isHibernated(tab)

        Button {
            selectedTabID = tab.id
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                        ? AdaptiveChrome.fill(colorScheme, dark: 0.12)
                        : AdaptiveChrome.fill(colorScheme, dark: 0.03))
                    .frame(width: 34, height: 34)
                    .opacity(isHib ? 0.6 : 1.0)

                if tab.kind == .passwords {
                    Image(systemName: "key.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(isHib ? 0.5 : 1.0)
                } else {
                    FaviconView(
                        pageURL: tab.pageURLString,
                        size: 18,
                        cornerRadius: 4,
                        loadRemote: !tab.isPrivate
                    )
                    .opacity(isHib ? 0.5 : 1.0)
                }

                if tab.isPrivate {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                        .offset(x: 12, y: -12)
                }

                // Onion (Tor) tab indicator — monochrome, per brand (no decorative color).
                if tab.privacyMode == .onion {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(2)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .offset(x: 12, y: -12)
                }

                // Pin dot (top-left corner, doesn't overlap privacy dot)
                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(2.5)
                        .background(Color.accentColor.opacity(0.8), in: Circle())
                        .offset(x: -11, y: -11)
                }

                if isHib {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(2)
                        .background(Color.black.opacity(0.3), in: Circle())
                        .offset(x: 11, y: -11)
                }

                if tab.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 6.5))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(2)
                        .background(Color.gray.opacity(0.7), in: Circle())
                        .offset(x: 11, y: 11)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async { hoveredTabID = hovering ? tab.id : nil }
        }
        .contextMenu { tabContextMenu(for: tab) }
        .help(tab.title.isEmpty ? "New Tab" : tab.title)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func tabContextMenu(for tab: BrowserTab) -> some View {
        Button {
            pinTabAction(tab)
        } label: {
            Label(
                tab.isPinned ? "Unpin Tab" : "Pin Tab",
                systemImage: tab.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            duplicateTabAction(tab)
        } label: {
            Label("Duplicate Tab", systemImage: "plus.square.on.square")
        }

        Button {
            muteTabAction(tab)
        } label: {
            Label(
                tab.isMuted ? "Unmute Tab" : "Mute Tab",
                systemImage: tab.isMuted ? "speaker.fill" : "speaker.slash.fill"
            )
        }
        .disabled(tab.kind != .web)

        Divider()

        Button(role: .destructive) {
            if let host = tab.currentURL?.host ?? tab.webView?.url?.host {
                forgetDomainAction(host)
            }
        } label: {
            Label(Localization.string("forget_this_site"), systemImage: "trash")
        }

        Button(role: .destructive) {
            guard !tab.isPinned else { return }
            closeTabAction(tab)
        } label: {
            Label(Localization.string("close_tab"), systemImage: "xmark")
        }
        .disabled(tab.isPinned)
    }

    // MARK: - Top zone

    private var topNavigationZone: some View {
        Group {
            if isCollapsed {
                VStack(spacing: 6) {
                    collapsedRailIconButton(
                        systemName: "plus",
                        help: Localization.string("new_tab"),
                        action: newTabAction
                    )

                    collapsedRailIconButton(
                        systemName: "chevron.right",
                        help: "Expand sidebar",
                        action: toggleCollapse
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 4)
            } else {
                HStack(spacing: 8) {
                    Button(action: newTabAction) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text(Localization.string("new_tab"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .glassPill(glassEnabled: glassEnabled)

                    if !PrivacyManager.shared.defaultNewTabsToPrivate {
                        Button(action: newPrivateTabAction) {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .glassIcon(size: 30, glassEnabled: glassEnabled)
                        .help("New Private Tab")
                    }

                    if hasClosedTabs, let reopen = reopenClosedTabAction {
                        Button(action: reopen) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .glassIcon(size: 30, glassEnabled: glassEnabled)
                        .help("Reopen Last Closed Tab")
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }

                    Button(action: toggleCollapse) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .glassIcon(size: 30, glassEnabled: glassEnabled)
                    .help("Collapse sidebar")
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hasClosedTabs)
                .padding(.horizontal, 10)
                .frame(height: AdaptiveChrome.slimToolbarRowHeight)
            }
        }
    }

    private func collapsedRailIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(AdaptiveChrome.fill(colorScheme, dark: 0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Bottom

    private var bottomFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AdaptiveChrome.divider(colorScheme))
                .frame(height: 1)
                .padding(.horizontal, isCollapsed ? 6 : 10)
                .padding(.top, 4)

            if isCollapsed {
                VStack(spacing: 4) {
                    BookmarksHistoryToolbarControl(
                        showingBookmarks: $showingBookmarks,
                        iconSize: 12,
                        frameSize: 32,
                        padding: 0
                    )

                    collapsedUtilityButton(systemName: "arrow.down.circle", isHovered: isDownloadsHovered) {
                        showingDownloads = true
                    } onHover: { isDownloadsHovered = $0 }
                }
                .padding(.vertical, 6)
            } else {
                utilityIconRow
                privacyStatusLine
                autoCleanupStatusLine
                Text("v0.7")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }
        }
    }

    private func collapsedUtilityButton(
        systemName: String,
        isHovered: Bool,
        action: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(isHovered ? AdaptiveChrome.fill(colorScheme, dark: 0.07) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async { onHover(hovering) }
        }
    }

    private var utilityIconRow: some View {
        HStack {
            BookmarksHistoryToolbarControl(
                showingBookmarks: $showingBookmarks,
                iconSize: 12,
                frameSize: 28,
                padding: 4
            )
            Spacer()
            utilityIcon(systemName: "arrow.down.circle", isHovered: isDownloadsHovered, action: {
                showingDownloads = true
            }) { isDownloadsHovered = $0 }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func utilityIcon(
        systemName: String,
        isHovered: Bool,
        action: @escaping () -> Void,
        onHoverChange: @escaping (Bool) -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .glassIcon(size: 30, glassEnabled: glassEnabled)
        .onHover { hovering in
            DispatchQueue.main.async { onHoverChange(hovering) }
        }
    }

    private var walletButton: some View {
        Button { showingWallet = true } label: {
            if isCollapsed {
                WalletBillfoldMark(color: .secondary)
                    .frame(width: 15, height: 15)
                    .frame(width: 32, height: 32)
                    .background(isWalletHovered ? AdaptiveChrome.fill(colorScheme, dark: 0.07) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    WalletBillfoldMark(color: .secondary)
                        .frame(width: 15, height: 15)
                    Text("Wallet")
                        .font(.system(size: 12.2, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isWalletHovered ? AdaptiveChrome.fill(colorScheme, dark: 0.045) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async { isWalletHovered = hovering }
        }
        .padding(.horizontal, isCollapsed ? 4 : 8)
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    }

    private var settingsButton: some View {
        Button { showingSettings = true } label: {
            if isCollapsed {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(isSettingsHovered ? AdaptiveChrome.fill(colorScheme, dark: 0.07) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(Localization.string("sidebar_settings"))
                        .font(.system(size: 12.2, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isSettingsHovered ? AdaptiveChrome.fill(colorScheme, dark: 0.045) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async { isSettingsHovered = hovering }
        }
        .padding(.horizontal, isCollapsed ? 4 : 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    }

    private var privacyStatusLine: some View {
        let pm = PrivacyManager.shared
        let history = pm.historyEnabled ? "History" : "No history"
        let priv = pm.defaultNewTabsToPrivate ? "Private default" : "Standard default"
        let enc = pm.dataEncryptionEnabled ? "• Encrypted" : ""

        return Text("\(history) • \(priv) \(enc)")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private var autoCleanupStatusLine: some View {
        let c = TabCleanupManager.shared
        if c.isEnabled {
            Text("Auto-cleanup on")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var hibernationTimerIndicator: some View {
        let remaining = max(0, TabHibernationManager.shared.secondsUntilNextAutoSweep)
        let timeString = String(format: "%d:%02d", remaining / 60, remaining % 60)

        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Hibernate in \(timeString)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
