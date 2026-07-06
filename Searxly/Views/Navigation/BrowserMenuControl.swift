//
//  BrowserMenuControl.swift
//  Searxly
//
//  The three-line (☰) header menu. Collapses the app-level features that used to be a row of
//  standalone toolbar icons (Reader, Find, Bookmarks & History, Downloads, Extensions, AI, Wallet,
//  Clear data, Import, Shortcuts, Settings) behind one button, so the webpage header stays clean.
//
//  Presented as a Liquid-Glass `.popover` (same chrome + arrow as the VPN / Tor pills). The ☰ is
//  given trailing room in RightToolbarControls so it isn't jammed in the window corner — when the
//  anchor is in the corner the popover edge-shifts and its arrow collides with the rounded corner,
//  which is what produced the "bubble". With room, the arrow centres cleanly like the VPN popover.
//

import SwiftUI

// MARK: - Header button

struct BrowserMenuControl: View {
    let glassEnabled: Bool
    let toolbarMaterial: Material
    let showingWebContent: Bool

    // Destinations that already have a flag in BrowserState.
    @Binding var showingBookmarks: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingKeyboardShortcuts: Bool

    // Page actions + app destinations supplied by the header (optional → row hidden when nil).
    var onReaderMode: (() -> Void)? = nil
    var onTranslatePage: (() -> Void)? = nil
    /// Current page is showing translations → the row flips to "Show Original".
    var isPageTranslated: Bool = false
    var onSummarizePage: (() -> Void)? = nil
    var onShowFind: (() -> Void)? = nil
    var onOpenLocalAIChat: (() -> Void)? = nil
    var onOpenExtensions: (() -> Void)? = nil
    var onOpenWallet: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onClearBrowsingData: (() -> Void)? = nil
    var onImportData: (() -> Void)? = nil

    @State private var showingMenu = false
    @State private var isHovering = false

    /// A transfer is in flight — surfaces the at-a-glance cue the header download ring used to give.
    private var hasActiveDownloads: Bool {
        DownloadsManager.shared.downloads.contains { !$0.isComplete && $0.error == nil }
    }

    var body: some View {
        Button { showingMenu = true } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 26)
                .overlay(alignment: .topTrailing) {
                    if hasActiveDownloads {
                        Circle()
                            .fill(SERPDesign.accentGreen)
                            .frame(width: 6, height: 6)
                            .shadow(color: SERPDesign.accentGreen.opacity(0.7), radius: 3)
                            .offset(x: 1, y: -1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(5)
        .background(
            (isHovering || showingMenu) ? BrowserMenuTheme.hoverFill : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: hasActiveDownloads)
        .onHover { isHovering = $0 }
        .help("Menu")
        .accessibilityLabel(Text("Menu"))
        // Liquid-glass popover with the arrow, exactly like the VPN / Tor pills. The ☰ is given
        // trailing room in RightToolbarControls so it isn't jammed in the corner — that keeps the
        // arrow off the popover's rounded corner (which is what produced the "bubble").
        .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
            menuPanel
        }
    }

    private var menuPanel: some View {
        BrowserMenuPanel(
            showingWebContent: showingWebContent,
            showingBookmarks: $showingBookmarks,
            showingDownloads: $showingDownloads,
            showingKeyboardShortcuts: $showingKeyboardShortcuts,
            onReaderMode: onReaderMode,
            onTranslatePage: onTranslatePage,
            isPageTranslated: isPageTranslated,
            onSummarizePage: onSummarizePage,
            onShowFind: onShowFind,
            onOpenLocalAIChat: onOpenLocalAIChat,
            onOpenExtensions: onOpenExtensions,
            onOpenWallet: onOpenWallet,
            onOpenSettings: onOpenSettings,
            onClearBrowsingData: onClearBrowsingData,
            onImportData: onImportData,
            onClose: { showingMenu = false }
        )
    }
}

// MARK: - Dropdown panel

private struct BrowserMenuPanel: View {
    let showingWebContent: Bool

    @Binding var showingBookmarks: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingKeyboardShortcuts: Bool

    var onReaderMode: (() -> Void)? = nil
    var onTranslatePage: (() -> Void)? = nil
    var isPageTranslated: Bool = false
    var onSummarizePage: (() -> Void)? = nil
    var onShowFind: (() -> Void)? = nil
    var onOpenLocalAIChat: (() -> Void)? = nil
    var onOpenExtensions: (() -> Void)? = nil
    var onOpenWallet: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onClearBrowsingData: (() -> Void)? = nil
    var onImportData: (() -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingWebContent,
               onReaderMode != nil || onTranslatePage != nil || onSummarizePage != nil || onShowFind != nil {
                section("THIS PAGE") {
                    if let onReaderMode {
                        BrowserMenuRow(icon: "doc.plaintext", label: "Reader View", shortcut: "⌘⇧R") {
                            onClose(); onReaderMode()
                        }
                    }
                    if onReaderMode != nil && onTranslatePage != nil { rowDivider }
                    if let onTranslatePage {
                        BrowserMenuRow(icon: "character.bubble",
                                       label: isPageTranslated ? "Show Original" : "Translate Page") {
                            onClose(); onTranslatePage()
                        }
                    }
                    if (onReaderMode != nil || onTranslatePage != nil) && onSummarizePage != nil { rowDivider }
                    if let onSummarizePage {
                        BrowserMenuRow(icon: "list.bullet.rectangle", label: "Summarize Page") {
                            onClose(); onSummarizePage()
                        }
                    }
                    if (onReaderMode != nil || onTranslatePage != nil || onSummarizePage != nil) && onShowFind != nil { rowDivider }
                    if let onShowFind {
                        BrowserMenuRow(icon: "magnifyingglass", label: "Find on Page", shortcut: "⌘F") {
                            onClose(); onShowFind()
                        }
                    }
                }
            }

            section("LIBRARY") {
                BrowserMenuRow(icon: "bookmark", label: "Bookmarks & History") {
                    onClose(); showingBookmarks = true
                }
                rowDivider
                BrowserMenuRow(icon: "arrow.down.circle", label: "Downloads") {
                    onClose(); showingDownloads = true
                }
                if let onOpenExtensions {
                    rowDivider
                    BrowserMenuRow(icon: "puzzlepiece.extension", label: "Extensions") {
                        onClose(); onOpenExtensions()
                    }
                }
            }

            if onOpenLocalAIChat != nil || onOpenWallet != nil {
                section("TOOLS") {
                    if let onOpenLocalAIChat {
                        BrowserMenuRow(icon: "sparkles", label: "AI Chat", shortcut: "⌘⌥A") {
                            onClose(); onOpenLocalAIChat()
                        }
                        if onOpenWallet != nil { rowDivider }
                    }
                    if let onOpenWallet {
                        BrowserMenuRow(icon: "creditcard", label: "Wallet") {
                            onClose(); onOpenWallet()
                        }
                    }
                }
            }

            if onClearBrowsingData != nil || onImportData != nil {
                section("PRIVACY & DATA") {
                    if let onClearBrowsingData {
                        BrowserMenuRow(icon: "trash", label: "Clear Browsing Data") {
                            onClose(); onClearBrowsingData()
                        }
                    }
                    if onClearBrowsingData != nil && onImportData != nil { rowDivider }
                    if let onImportData {
                        BrowserMenuRow(icon: "square.and.arrow.down", label: "Import Data") {
                            onClose(); onImportData()
                        }
                    }
                }
            }

            appSection
        }
        // Solid canvas exactly like SearxlyVPNPanel / Passwords — the `.popover` chrome supplies
        // the Liquid Glass surround + arrow. (No inner rounded card: that would float a box inside the
        // popover's own shape.) Follows the app appearance: near-black in dark, white in light.
        .padding(16)
        .frame(width: 300)
        .background(BrowserMenuTheme.canvas)
    }

    // MARK: App section (lock / shortcuts / settings)

    private var appSection: some View {
        section("APP") {
            if AppLockManager.shared.isAppLockEnabled {
                BrowserMenuRow(icon: "lock.fill", label: "Lock Searxly Now", shortcut: "⌘⌥L") {
                    onClose(); AppLockManager.shared.lock()
                }
                rowDivider
            }
            BrowserMenuRow(icon: "questionmark.circle", label: "Keyboard Shortcuts", shortcut: "⌘?") {
                onClose(); showingKeyboardShortcuts = true
            }
            if let onOpenSettings {
                rowDivider
                BrowserMenuRow(icon: "gearshape", label: "Settings") {
                    onClose(); onOpenSettings()
                }
            }
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(BrowserMenuTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(BrowserMenuTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var rowDivider: some View {
        Divider().overlay(BrowserMenuTheme.hairline).padding(.leading, 12)
    }
}

// MARK: - Row

private struct BrowserMenuRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var tint: Color = .primary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(tint.opacity(0.92))
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.32))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isHovering ? BrowserMenuTheme.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Theme
// Mirrors SearxlyVPNTheme / PasswordsPanelTheme so the menu reads as the same glass surface as
// the VPN / Tor / Passwords panels. Each panel re-declares its own copy (per the existing pattern).
// Adaptive: near-black panel in dark mode, white panel in light mode.
private enum BrowserMenuTheme {
    static let canvas = AdaptiveChrome.dynamic(
        light: .white,
        dark: Color(red: 0.043, green: 0.043, blue: 0.051)
    )
    static let card      = AdaptiveChrome.dynamic(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.05))
    static let hairline  = AdaptiveChrome.dynamic(light: Color.black.opacity(0.085), dark: Color.white.opacity(0.09))
    static let hoverFill = AdaptiveChrome.dynamic(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.07))
}
