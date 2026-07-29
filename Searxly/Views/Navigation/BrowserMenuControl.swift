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

    /// The current page's URL, so the menu can offer "Copy Clean Link" (tracker-stripped). Nil on the
    /// new-tab / home surface.
    var currentPageURL: URL? = nil

    // Page actions + app destinations supplied by the header (optional → row hidden when nil).
    var onReaderMode: (() -> Void)? = nil
    var onTranslatePage: (() -> Void)? = nil
    /// Current page is showing translations → the row flips to "Show Original".
    var isPageTranslated: Bool = false
    var onShowFind: (() -> Void)? = nil
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
            currentPageURL: currentPageURL,
            showingBookmarks: $showingBookmarks,
            showingDownloads: $showingDownloads,
            showingKeyboardShortcuts: $showingKeyboardShortcuts,
            onReaderMode: onReaderMode,
            onTranslatePage: onTranslatePage,
            isPageTranslated: isPageTranslated,
            onShowFind: onShowFind,
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
    var currentPageURL: URL? = nil

    @Binding var showingBookmarks: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingKeyboardShortcuts: Bool

    var onReaderMode: (() -> Void)? = nil
    var onTranslatePage: (() -> Void)? = nil
    var isPageTranslated: Bool = false
    var onShowFind: (() -> Void)? = nil
    var onOpenExtensions: (() -> Void)? = nil
    var onOpenWallet: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onClearBrowsingData: (() -> Void)? = nil
    var onImportData: (() -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Searxly Maximum: security controls at the top — the fastest place to change posture
            // without opening Settings. Absent in the base app.
            if Edition.isMaximum {
                maximumSecuritySection
            }

            if showingWebContent,
               onReaderMode != nil || onTranslatePage != nil || onShowFind != nil || currentPageURL != nil {
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
                    if (onReaderMode != nil || onTranslatePage != nil) && onShowFind != nil { rowDivider }
                    if let onShowFind {
                        BrowserMenuRow(icon: "magnifyingglass", label: "Find on Page", shortcut: "⌘F") {
                            onClose(); onShowFind()
                        }
                    }
                    // Copy the current URL with tracking parameters removed — keeps the menu open so
                    // the "copied" confirmation is visible.
                    if let currentPageURL {
                        if onReaderMode != nil || onTranslatePage != nil || onShowFind != nil { rowDivider }
                        CopyCleanLinkRow(url: currentPageURL)
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

            section("TOOLS") {
                BrowserMenuRow(icon: "sparkles", label: "Connect your AI") {
                    onClose()
                    NotificationCenter.default.post(name: .openSettingsToAgenticTools, object: nil)
                }
                if let onOpenWallet {
                    rowDivider
                    BrowserMenuRow(icon: "creditcard", label: "Wallet") {
                        onClose(); onOpenWallet()
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

    // MARK: Maximum security section (level / new identity / status)

    private var maximumSecuritySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SECURITY LEVEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            SecurityLevelSelector()

            VStack(spacing: 0) {
                BrowserMenuRow(icon: "arrow.triangle.2.circlepath", label: "New Identity", shortcut: "⌘⇧U") {
                    onClose()
                    NotificationCenter.default.post(name: .newIdentityRequested, object: nil)
                }
                if onOpenSettings != nil {
                    rowDivider
                    BrowserMenuRow(icon: "checkmark.shield", label: "Security Status") {
                        onClose(); onOpenSettings?()
                    }
                }
            }
            .background(BrowserMenuTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(BrowserMenuTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
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

// MARK: - Copy clean link

/// Copies the current URL with tracking parameters stripped (via NavigationGuard). Confirms inline —
/// and distinguishes "trackers removed" from a link that was already clean — instead of closing the
/// menu, so the feedback is actually seen.
private struct CopyCleanLinkRow: View {
    let url: URL

    private enum Feedback { case idle, removed, alreadyClean }
    @State private var feedback: Feedback = .idle
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 11) {
                Image(systemName: iconName)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(feedback == .idle ? Color.primary.opacity(0.92) : SERPDesign.accentGreen)
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isHovering ? BrowserMenuTheme.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: feedback)
    }

    private var iconName: String {
        switch feedback {
        case .idle:         return "link"
        case .removed, .alreadyClean: return "checkmark"
        }
    }

    private var label: String {
        switch feedback {
        case .idle:         return "Copy Clean Link"
        case .removed:      return "Copied — trackers removed"
        case .alreadyClean: return "Copied — already clean"
        }
    }

    private func copy() {
        let cleaned = NavigationGuard.strippingTrackingParams(from: url)
        let toCopy = cleaned ?? url
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(toCopy.absoluteString, forType: .string)

        feedback = (cleaned != nil) ? .removed : .alreadyClean
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            feedback = .idle
        }
    }
}

// MARK: - Security level selector (Searxly Maximum)

/// Three-segment selector for the Standard / Safer / Safest security level, live from
/// `MaximumSecurity`. The active segment is filled; a one-line summary sits underneath so the
/// choice's cost is visible without opening Settings.
private struct SecurityLevelSelector: View {
    @State private var level: MaximumSecurityLevel = MaximumSecurity.effective

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(MaximumSecurityLevel.allCases, id: \.self) { option in
                    segment(option)
                }
            }
            .padding(3)
            .background(BrowserMenuTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(BrowserMenuTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(level.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .onReceive(NotificationCenter.default.publisher(for: MaximumSecurity.levelChangedNotification)) { _ in
            level = MaximumSecurity.effective
        }
    }

    private func segment(_ option: MaximumSecurityLevel) -> some View {
        let selected = option == level
        return Button {
            MaximumSecurity.shared.setLevel(option)
            level = option
        } label: {
            Text(option.displayName)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? BrowserMenuTheme.onAccent : Color.primary.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? BrowserMenuTheme.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: level)
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
    /// Ink accent for the active security-level segment: near-black pill in light, white in dark
    /// (monochrome — matches the Settings toggle "on" ink). `onAccent` is the text over it.
    static let accent    = AdaptiveChrome.dynamic(light: Color(white: 0.14), dark: .white)
    static let onAccent  = AdaptiveChrome.dynamic(light: .white, dark: .black)
}
