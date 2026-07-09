//
//  RightToolbarControls.swift
//  Searxly
//
//  Extracted the right-hand side of the main toolbar (navigation + bookmarks +
//  downloads + settings). Updated during monster views refactor (ContentView is now thin;
//  state/logic in BrowserState.swift).
//

import SwiftUI
import WebKit

struct RightToolbarControls: View {
    let activeWebView: WKWebView
    let showingWebContent: Bool
    let glassEnabled: Bool
    let toolbarMaterial: Material

    // Live navigation state (updated via KVO in WebViewRepresentable)
    let canGoBack: Bool
    let canGoForward: Bool

    @Binding var bookmarks: [BookmarkItem]
    @Binding var webPageTitle: String
    @Binding var showingBookmarks: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingKeyboardShortcuts: Bool

    // New actions for extracted features (passed from parent to avoid global notifications)
    var onShowFind: (() -> Void)? = nil

    /// Optional current web domain for "Save current login" in the passwords pill.
    var currentWebDomain: String? = nil

    /// Lightweight page context for password detection (no full system autofill).
    /// Used to offer "generate password directly in the browser" when a password field is present.
    var hasPasswordFieldOnPage: Bool = false
    var isLikelySignupForm: Bool = false

    /// Callback for generating + filling a password straight into the current page.
    var onGeneratePasswordForPage: (() -> Void)? = nil

    /// Save credentials from the current page into the vault.
    var onSaveLoginFromPage: (() -> Void)? = nil

    /// Fill a saved login on the current page (domain, username, password).
    var onFillLogin: ((String, String, String) -> Void)? = nil

    /// Canonical bookmark action (preferred). Falls back to legacy direct mutation if nil (for old call sites).
    var onBookmarkCurrentPage: (() -> Void)? = nil

    var onGoBack: (() -> Void)? = nil
    var onGoForward: (() -> Void)? = nil

    // App-level destinations consolidated into the ☰ menu (supplied by the header from BrowserState).
    var onOpenExtensions: (() -> Void)? = nil
    var onOpenWallet: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onClearBrowsingData: (() -> Void)? = nil
    var onImportData: (() -> Void)? = nil

    private var showsNavigationControls: Bool {
        showingWebContent || canGoBack || canGoForward
    }

    var body: some View {
        HStack(spacing: 2) {
            if showsNavigationControls {
                HStack(spacing: 2) {
                    FlatIconButton(
                        systemName: "chevron.backward",
                        isEnabled: canGoBack,
                        shortcutKey: "[",
                        shortcutModifiers: .command,
                        help: "Back (⌘[)"
                    ) {
                        if let onGoBack {
                            onGoBack()
                        } else {
                            activeWebView.goBack()
                        }
                    }

                    FlatIconButton(
                        systemName: "chevron.forward",
                        isEnabled: canGoForward,
                        shortcutKey: "]",
                        shortcutModifiers: .command,
                        help: "Forward (⌘])"
                    ) {
                        if let onGoForward {
                            onGoForward()
                        } else {
                            activeWebView.goForward()
                        }
                    }

                    if showingWebContent {
                        FlatIconButton(
                            systemName: "arrow.clockwise",
                            isEnabled: true,
                            shortcutKey: "r",
                            shortcutModifiers: .command,
                            help: "Reload (⌘R)"
                        ) {
                            activeWebView.reload()
                        }
                    }

                    if showingWebContent {
                    // Bookmark toggle (star) — filled when saved; tap again to remove.
                    let currentURLStr = activeWebView.url?.absoluteString
                    let isBookmarked = currentURLStr.map { BookmarkURLMatcher.contains(url: $0, in: bookmarks) } ?? false
                    FlatIconButton(
                        systemName: isBookmarked ? "star.fill" : "star",
                        isEnabled: true,
                        shortcutKey: "d",
                        shortcutModifiers: .command,
                        help: isBookmarked ? "Remove bookmark (⌘D)" : "Bookmark this page (⌘D)"
                    ) {
                        if let bm = onBookmarkCurrentPage {
                            bm()
                        } else if let urlStr = activeWebView.url?.absoluteString {
                            // Legacy direct path (keeps old call sites like legacy TopBarArea working).
                            var updated = bookmarks
                            if BookmarkURLMatcher.contains(url: urlStr, in: updated) {
                                BookmarkURLMatcher.remove(url: urlStr, from: &updated)
                            } else {
                                let title = webPageTitle.isEmpty ? (activeWebView.url?.host ?? "Untitled") : webPageTitle
                                BookmarkURLMatcher.remove(url: urlStr, from: &updated)
                                let item = BookmarkItem(url: urlStr, title: title)
                                updated.insert(item, at: 0)
                                if updated.count > BookmarkLimits.maxCount { updated.removeLast(updated.count - BookmarkLimits.maxCount) }
                            }
                            bookmarks = updated
                            Persistence.saveBookmarks(updated)
                        }
                    }
                    }
                }
                .padding(.trailing, 6)
            }

            // Passwords pill — a glass capsule like the VPN / Tor pills, set apart from the flat
            // icons. Stays in the header (core privacy feature); goes green when the current site
            // has a saved login.
            PasswordsBrowserControl(
                glassEnabled: glassEnabled,
                toolbarMaterial: toolbarMaterial,
                currentWebDomain: currentWebDomain,
                hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                isLikelySignupForm: isLikelySignupForm,
                onGeneratePasswordForPage: onGeneratePasswordForPage,
                onSaveLoginFromPage: onSaveLoginFromPage,
                onFillLogin: onFillLogin
            )
            .padding(.leading, 6)

            // ☰ menu — everything else (Reader, Find, Bookmarks & History, Downloads, Extensions,
            // AI, Wallet, Clear data, Import, Shortcuts, Settings) lives here to keep the header clean.
            BrowserMenuControl(
                glassEnabled: glassEnabled,
                toolbarMaterial: toolbarMaterial,
                showingWebContent: showingWebContent,
                showingBookmarks: $showingBookmarks,
                showingDownloads: $showingDownloads,
                showingKeyboardShortcuts: $showingKeyboardShortcuts,
                // Reader reuses the ⌘⇧R menu-command route (ContentView owns the reader state);
                // Translate talks to the shared on-device translator with this header's webview.
                onReaderMode: { NotificationCenter.default.post(name: .readerModeRequested, object: nil) },
                onTranslatePage: { PageTranslator.shared.toggleTranslation(for: activeWebView) },
                isPageTranslated: PageTranslator.shared.isTranslated(activeWebView),
                onShowFind: onShowFind,
                onOpenExtensions: onOpenExtensions,
                onOpenWallet: onOpenWallet,
                onOpenSettings: onOpenSettings,
                onClearBrowsingData: onClearBrowsingData,
                onImportData: onImportData
            )
            .padding(.leading, 2)
            // Keep the ☰ off the window's right edge so its popover arrow sits on the flat top edge of
            // the panel, well clear of the rounded corner (corner collision is what made the "bubble").
            .padding(.trailing, 34)
        }
    }
}

// Flat icon button for header toolbar (no glassy bubble/circle).
// Clean, modern, subtle hover state only.
private struct FlatIconButton: View {
    let systemName: String
    let isEnabled: Bool

    // Optional keyboard shortcut support (for common browser shortcuts like ⌘R, ⌘[, etc.)
    // Declared before `action` so trailing closure syntax continues to work when providing shortcuts.
    var shortcutKey: KeyEquivalent? = nil
    var shortcutModifiers: EventModifiers = []
    var help: String? = nil

    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.35))
                .frame(width: 26, height: 26)
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
        .padding(5)
        .background(
            isHovering && isEnabled
                ? AdaptiveChrome.dynamic(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.065))
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .opacity(isEnabled ? 1.0 : 0.5)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .if(shortcutKey != nil) { view in
            view.keyboardShortcut(shortcutKey!, modifiers: shortcutModifiers)
        }
        .if(help != nil) { view in
            view.help(help!)
        }
        // Icon-only button — give VoiceOver a spoken label (the tooltip text, or the SF Symbol name as a fallback).
        .accessibilityLabel(Text(help ?? systemName))
    }
}

// Small helper to conditionally apply a modifier (keeps call sites clean)
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - PasswordsBrowserControl
struct PasswordsBrowserControl: View {
    @Environment(\.colorScheme) private var colorScheme

    let glassEnabled: Bool
    let toolbarMaterial: Material

    var currentWebDomain: String? = nil
    var hasPasswordFieldOnPage: Bool = false
    var isLikelySignupForm: Bool = false

    var onGeneratePasswordForPage: (() -> Void)? = nil
    var onSaveLoginFromPage: (() -> Void)? = nil
    var onFillLogin: ((String, String, String) -> Void)? = nil

    @State private var showingPopover = false

    private var vault = PasswordVaultManager.shared
    private var domainLogins: [PasswordVaultEntry] {
        guard let domain = currentWebDomain else { return [] }
        return vault.entries(forDomain: domain)
    }

    private var passwordsHelp: String {
        if domainLogins.isEmpty {
            return "Passwords"
        }
        let countLabel = domainLogins.count == 1 ? "login" : "logins"
        return "Passwords — \(domainLogins.count) saved \(countLabel) for this site"
    }

    var body: some View {
        // Glass capsule pill matching the VPN / Tor pills: icon + label + status dot. The dot and
        // border go green when the current site has a saved login — the same active-state language
        // those pills use when they're on. Independent of lock state: the entry's existence is the cue.
        let hasRegisteredLogin = !domainLogins.isEmpty
        let statusTint = hasRegisteredLogin ? SERPDesign.accentGreen : Color(white: 0.5)

        Button {
            showingPopover = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Passwords")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.3)
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
                    .shadow(color: hasRegisteredLogin ? statusTint.opacity(0.7) : .clear, radius: 3)
                    .animation(.easeInOut(duration: 0.25), value: hasRegisteredLogin)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(toolbarMaterial, in: Capsule())
            .searxlyGlass(glassEnabled ? .interactive : .clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    hasRegisteredLogin ? statusTint.opacity(0.5) : AdaptiveChrome.border(colorScheme, dark: 0.12),
                    lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(passwordsHelp)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            PasswordsPopoverContent(
                currentWebDomain: currentWebDomain,
                domainLogins: domainLogins,
                hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                isLikelySignupForm: isLikelySignupForm,
                onGeneratePasswordForPage: onGeneratePasswordForPage,
                onSaveLoginFromPage: onSaveLoginFromPage,
                onFillLogin: onFillLogin,
                onClose: { showingPopover = false }
            )
        }
        .onAppear {
            vault.reloadFromPersistence()
        }
    }
}

private struct PasswordsPopoverContent: View {
    let currentWebDomain: String?
    let domainLogins: [PasswordVaultEntry]
    let hasPasswordFieldOnPage: Bool
    let isLikelySignupForm: Bool

    var onGeneratePasswordForPage: (() -> Void)? = nil
    var onSaveLoginFromPage: (() -> Void)? = nil
    var onFillLogin: ((String, String, String) -> Void)? = nil
    let onClose: () -> Void

    private var vault = PasswordVaultManager.shared

    @State private var passphraseInput: String = ""
    @State private var unlockError: Bool = false
    @State private var isUnlocking: Bool = false

    @State private var revealedEntryIDs: Set<UUID> = []
    @State private var revealedPasswords: [UUID: String] = [:]

    @State private var isAddingNew: Bool = false
    @State private var newUsername: String = ""
    @State private var newPassword: String = ""
    @State private var showNewPassword: Bool = false

    var body: some View {
        Group {
            if !vault.isVaultUnlocked {
                lockedView
            } else if isAddingNew {
                addLoginView
            } else {
                unlockedView
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(PasswordsPanelTheme.canvas)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: vault.isVaultUnlocked)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: isAddingNew)
        // Passwords panel — exclude from screenshots / screen recording while open (it can reveal stored passwords).
        .screenCaptureProtected()
    }

    // MARK: - Locked

    private var lockedView: some View {
        VStack(alignment: .leading, spacing: 13) {
            panelHeader(
                icon: "lock.fill",
                title: "Passwords",
                subtitle: "Vault is locked",
                subtitleTint: Color(white: 0.5)
            ) {
                statusDot(Color(white: 0.5), glow: false)
            }

            VStack(spacing: 11) {
                if vault.useCustomVaultPassphrase {
                    VStack(alignment: .leading, spacing: 7) {
                        sectionLabel("VAULT PASSWORD")
                        SecureField("Enter vault password", text: $passphraseInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background { cardBackground(cornerRadius: 10) }
                            .onSubmit { Task { await unlockWithPassphrase() } }
                        if unlockError { errorLine("Incorrect password. Try again.") }
                    }

                    primaryButton(
                        title: isUnlocking ? "Unlocking…" : "Unlock",
                        busy: isUnlocking,
                        enabled: !passphraseInput.isEmpty
                    ) {
                        Task { await unlockWithPassphrase() }
                    }
                } else {
                    primaryButton(
                        title: isUnlocking ? "Authenticating…" : "Unlock",
                        systemImage: "touchid",
                        busy: isUnlocking
                    ) {
                        Task { await unlockWithBiometrics() }
                    }
                    if unlockError { errorLine("Authentication failed. Try again.") }
                }
            }
            .padding(14)
            .background { cardBackground(cornerRadius: 14) }

            openVaultRow
        }
    }

    // MARK: - Unlocked

    private var unlockedView: some View {
        VStack(alignment: .leading, spacing: 13) {
            panelHeader(
                icon: "key.fill",
                iconTint: PasswordsPanelTheme.green,
                title: "Passwords",
                subtitle: currentWebDomain ?? {
                    let n = vault.savedLoginCount
                    return "\(n) saved login\(n == 1 ? "" : "s")"
                }(),
                subtitleTint: PasswordsPanelTheme.subtitle
            ) {
                Button { vault.lockVault() } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background { cardBackground(cornerRadius: 8) }
                }
                .buttonStyle(.plain)
                .help("Lock vault")
            }

            if !domainLogins.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("SAVED FOR THIS SITE")
                    VStack(spacing: 0) {
                        ForEach(domainLogins) { entry in
                            loginRow(entry)
                            if entry.id != domainLogins.last?.id { rowDivider }
                        }
                    }
                    .background { cardBackground(cornerRadius: 12) }
                }
            }

            let showGenerate = hasPasswordFieldOnPage && vault.suggestPasswordsEnabled && onGeneratePasswordForPage != nil
            let showSave = (hasPasswordFieldOnPage || isLikelySignupForm) && vault.offerToSaveEnabled && onSaveLoginFromPage != nil
            let showNewEntry = currentWebDomain != nil

            if showGenerate || showSave || showNewEntry {
                VStack(spacing: 0) {
                    if showGenerate {
                        actionRow(icon: "wand.and.stars", label: "Generate & fill password") {
                            onGeneratePasswordForPage?(); onClose()
                        }
                    }
                    if showSave {
                        if showGenerate { rowDivider }
                        actionRow(icon: "square.and.arrow.down", label: "Save current login") {
                            onSaveLoginFromPage?(); onClose()
                        }
                    }
                    if showNewEntry, let domain = currentWebDomain {
                        if showGenerate || showSave { rowDivider }
                        actionRow(icon: "plus.circle", label: "New login for \(domain)") {
                            startAddingNew()
                        }
                    }
                }
                .background { cardBackground(cornerRadius: 12) }
            }

            openVaultRow
        }
    }

    // MARK: - Add Login

    private var addLoginView: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Button { isAddingNew = false } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                        .background { cardBackground(cornerRadius: 8) }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New Login").font(.system(size: 14, weight: .bold))
                    if let domain = currentWebDomain {
                        Text(domain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("USERNAME OR EMAIL")
                    TextField("username@example.com", text: $newUsername)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background { cardBackground(cornerRadius: 10) }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionLabel("PASSWORD")
                        Spacer()
                        Button {
                            newPassword = Self.makePassword()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Generate")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(Color.primary.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 6) {
                        Group {
                            if showNewPassword {
                                TextField("password", text: $newPassword)
                            } else {
                                SecureField("password", text: $newPassword)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))

                        Button {
                            showNewPassword.toggle()
                        } label: {
                            Image(systemName: showNewPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background { cardBackground(cornerRadius: 10) }
                }

                HStack(spacing: 8) {
                    secondaryButton(title: "Cancel") { isAddingNew = false }
                    primaryButton(
                        title: "Save Login",
                        enabled: !newUsername.trimmingCharacters(in: .whitespaces).isEmpty && !newPassword.isEmpty
                    ) {
                        saveNewLogin()
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Shared subviews (dark-glass styling matches the VPN / Tor panels)

    @ViewBuilder
    private func panelHeader<Trailing: View>(
        icon: String,
        iconTint: Color = .primary,
        title: String,
        subtitle: String,
        subtitleTint: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PasswordsPanelTheme.fillSubtle)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(subtitleTint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            trailing()
        }
    }

    private func statusDot(_ tint: Color, glow: Bool) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .shadow(color: glow ? tint.opacity(0.7) : .clear, radius: 4)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(.tertiary)
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(PasswordsPanelTheme.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(PasswordsPanelTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PasswordsPanelTheme.hairline, lineWidth: 1)
            )
    }

    private var rowDivider: some View {
        Divider().overlay(PasswordsPanelTheme.hairline).padding(.leading, 12)
    }

    private func primaryButton(
        title: String,
        systemImage: String? = nil,
        busy: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(PasswordsPanelTheme.onInk)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(PasswordsPanelTheme.onInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(PasswordsPanelTheme.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.45)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(PasswordsPanelTheme.fillSubtle, in: Capsule())
                .overlay(Capsule().strokeBorder(PasswordsPanelTheme.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    @ViewBuilder
    private func loginRow(_ entry: PasswordVaultEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(entry.username)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let pwd = revealedPasswords[entry.id] {
                        Text(pwd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("••••••••••")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .tracking(2)
                    }
                }
            }
            Spacer()
            HStack(spacing: 6) {
                iconButton(
                    revealedEntryIDs.contains(entry.id) ? "eye.slash" : "eye",
                    help: revealedEntryIDs.contains(entry.id) ? "Hide password" : "Show password"
                ) { toggleReveal(entry) }

                iconButton("doc.on.doc", help: "Copy password") { copyPassword(entry) }

                Button { fill(entry) } label: {
                    Text("Autofill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(PasswordsPanelTheme.fillSubtle, in: Capsule())
                        .overlay(Capsule().strokeBorder(PasswordsPanelTheme.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Autofill on this page")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(Color.primary.opacity(0.9))
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var openVaultRow: some View {
        Button {
            NotificationCenter.default.post(name: .showPasswordsVaultTabRequested, object: nil)
            onClose()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.9))
                Text("Open Vault")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { cardBackground(cornerRadius: 12) }
    }

    private func startAddingNew() {
        newUsername = ""
        newPassword = Self.makePassword()
        showNewPassword = false
        isAddingNew = true
    }

    // MARK: - Logic

    private func unlockWithBiometrics() async {
        isUnlocking = true
        unlockError = false
        let success = await vault.unlockVault()
        isUnlocking = false
        if !success { unlockError = true }
    }

    private func unlockWithPassphrase() async {
        guard !passphraseInput.isEmpty else { return }
        isUnlocking = true
        unlockError = false
        let success = await vault.unlockVault(passphrase: passphraseInput)
        isUnlocking = false
        if success { passphraseInput = "" } else { unlockError = true }
    }

    private func toggleReveal(_ entry: PasswordVaultEntry) {
        if revealedEntryIDs.contains(entry.id) {
            revealedEntryIDs.remove(entry.id)
            revealedPasswords.removeValue(forKey: entry.id)
        } else if let pwd = vault.password(for: entry.id) {
            revealedEntryIDs.insert(entry.id)
            revealedPasswords[entry.id] = pwd
        }
    }

    private func copyPassword(_ entry: PasswordVaultEntry) {
        guard let pwd = vault.password(for: entry.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pwd, forType: .string)
        vault.markEntryUsed(id: entry.id)
    }

    private func fill(_ entry: PasswordVaultEntry) {
        guard vault.autofillEnabled,
              let password = vault.password(for: entry.id),
              let domain = currentWebDomain else { return }
        vault.markEntryUsed(id: entry.id)
        onFillLogin?(domain, entry.username, password)
        onClose()
    }

    private func saveNewLogin() {
        guard let domain = currentWebDomain else { return }
        let user = newUsername.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !newPassword.isEmpty else { return }
        vault.addEntry(domain: domain, username: user, password: newPassword)
        isAddingNew = false
    }

    private static func makePassword(length: Int = 20) -> String {
        let chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%&*"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }
}

// MARK: - Passwords panel theme
// Mirrors SearxlyVPNTheme / TorPillTheme so the Passwords popover reads as the same glass
// surface as the VPN and Tor panels: solid canvas, faint cards + hairlines, green only
// for live/unlocked status (per the monochrome brand). Adaptive: near-black in dark, white in light.
private enum PasswordsPanelTheme {
    static let canvas = AdaptiveChrome.dynamic(
        light: .white,
        dark: Color(red: 0.043, green: 0.043, blue: 0.051)
    )
    static let card           = AdaptiveChrome.dynamic(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.05))
    static let hairline       = AdaptiveChrome.dynamic(light: Color.black.opacity(0.085), dark: Color.white.opacity(0.09))
    static let hairlineStrong = AdaptiveChrome.dynamic(light: Color.black.opacity(0.16), dark: Color.white.opacity(0.14))
    static let fillSubtle     = AdaptiveChrome.dynamic(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.08))
    static let subtitle       = AdaptiveChrome.dynamic(light: Color(white: 0.42), dark: Color(white: 0.6))
    /// Solid "ink" primary button — white-on-black in dark, black-on-white in light.
    static let ink   = AdaptiveChrome.dynamic(light: Color(white: 0.12), dark: .white)
    static let onInk = AdaptiveChrome.dynamic(light: .white, dark: .black)
    static let green = SERPDesign.accentGreen
    static let red = AdaptiveChrome.dynamic(
        light: Color(red: 0.78, green: 0.22, blue: 0.22),
        dark: Color(red: 1.0, green: 0.45, blue: 0.45)
    )
}
