//
//  AddressBar.swift
//  Searxly
//
//  Plain unified address/search bar (the visual + TextField part).
//  Suggestions feature (including search history, bookmarks, statics) has been DELETED per user request.
//  No dropdowns are shown or updated from the address bar (home or header).
//  The bar is a simple focused TextField. Legacy suggestion params in init are ignored.
//  Submit (Return) or the parent decides what to do with the text.
//  Styling matches the rest of the app (glass, focus ring, scale, shadow) with simple hero vs slim sizing.

import AppKit
import SwiftUI

struct AddressBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Slim header bar bounds in the parent `mainColumn` coordinate space (for anchoring suggestions).
struct AddressBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct AddressBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    let showingWebContent: Bool
    let glassEnabled: Bool
    let toolbarMaterial: Material
    let onSubmit: () -> Void

    /// Larger, more prominent metrics + positioning for the centered bar on pure home/new tab.
    var isHero: Bool = false

    /// When the active tab is a Tor-routed onion tab, the leading icon becomes the onion glyph.
    var isOnionTab: Bool = false

    /// Registrable host of the current page, used by the site-privacy popover (empty on home/search).
    var siteHost: String = ""

    // Suggestion keyboard hooks are no longer used (suggestions feature DELETED per user request).
    // Params kept with defaults for any remaining call sites during cleanup; they are ignored.
    private let onSuggestionsArrowDown: (() -> Void)?
    private let onSuggestionsArrowUp: (() -> Void)?
    private let onSuggestionsEscape: (() -> Void)?

    init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        showingWebContent: Bool,
        glassEnabled: Bool,
        toolbarMaterial: Material,
        history: [HistoryItem] = [],
        bookmarks: [BookmarkItem] = [],
        onSubmit: @escaping () -> Void,
        isHero: Bool = false,
        isOnionTab: Bool = false,
        siteHost: String = "",
        isCompact: Bool = false,
        suppressSuggestions: Bool = false,
        drawsOwnSuggestionsOverlay: Bool = true,
        isSuggestionsPanelHoisted: Binding<Bool> = .constant(false),
        hoistedSuggestionsPanelWidth: Binding<CGFloat> = .constant(520),
        hoistedSelectedIndex: Binding<Int> = .constant(0),
        isSuggestionsPanelOpen: Bool = false,
        isSuggestionsPanelVisible: Binding<Bool> = .constant(false),
        suggestionsPanelFrame: Binding<CGRect> = .constant(.zero),
        suggestionsSelectedIndex: Binding<Int> = .constant(0),
        onSuggestionsArrowDown: (() -> Void)? = nil,
        onSuggestionsArrowUp: (() -> Void)? = nil,
        onSuggestionsEscape: (() -> Void)? = nil
    ) {
        self._text = text
        self._isFocused = isFocused
        self.showingWebContent = showingWebContent
        self.glassEnabled = glassEnabled
        self.toolbarMaterial = toolbarMaterial
        self.onSubmit = onSubmit
        self.isHero = isHero
        self.isOnionTab = isOnionTab
        self.siteHost = siteHost

        self.onSuggestionsArrowDown = onSuggestionsArrowDown
        self.onSuggestionsArrowUp = onSuggestionsArrowUp
        self.onSuggestionsEscape = onSuggestionsEscape
    }

    // MARK: - Sizing (hero = big centered on home; slim when web content or in header)

    private var isBrowserBar: Bool { showingWebContent && !isHero }

    @Environment(\.colorScheme) private var colorScheme

    /// Searxly Maximum's hero bar in dark mode — the only address bar on its pure home state, sitting on
    /// the pitch-black home canvas. Frosted material and Liquid Glass both turn into a bright pill
    /// floating on nothing there, so this bar opts out of both. Glass-independent: reducing liquid glass
    /// can only ever make the app flatter, never glassier, so both settings land on the same surface.
    /// The base app's hero bar keeps its glass — see HomeAmbientBackground for the two canvases.
    private var isDarkHero: Bool { Edition.isMaximum && isHero && colorScheme == .dark }
    @State private var showingPrivacyStatus = false

    /// The NSWindow hosting this bar, resolved via `WindowAccessor`. Used to resign the web view's
    /// first responder before taking focus (see `focusField()`).
    @State private var hostWindow: NSWindow?

    /// The leading glyph. On a loaded web page it becomes a button that opens the site-privacy popover
    /// (the spot users click for security info); on home/search it's a plain search/globe icon.
    @ViewBuilder
    private var leadingIcon: some View {
        let image = Image(systemName: isOnionTab ? "point.3.connected.trianglepath.dotted" : (showingWebContent ? "globe" : "magnifyingglass"))
            .foregroundStyle(.secondary.opacity(isHero ? 1.0 : 0.9))
            .font(.system(size: iconSize, weight: .regular))

        if showingWebContent {
            Button { showingPrivacyStatus.toggle() } label: { image }
                .buttonStyle(.plain)
                .help("Site privacy & security")
                .accessibilityLabel(Text("Site privacy and security"))
                .popover(isPresented: $showingPrivacyStatus, arrowEdge: .bottom) {
                    PrivacyStatusView(host: siteHost, isOnionTab: isOnionTab)
                }
        } else {
            image
        }
    }

    private var verticalPadding: CGFloat {
        if isHero { return 14 }
        if isBrowserBar { return 5 }
        return 7
    }

    private var horizontalPadding: CGFloat {
        if isHero { return 18 }
        if isBrowserBar { return 10 }
        return 12
    }

    private var cornerRadius: CGFloat {
        if isHero { return 18 }
        if isBrowserBar { return 11 }
        return 12
    }

    private var iconSize: CGFloat {
        if isHero { return 17 }
        if isBrowserBar { return 12 }
        return 13
    }

    private var fontSize: CGFloat {
        if isHero { return 16.5 }
        if isBrowserBar { return 13.5 }
        return 14
    }

    /// The host to emphasize when the bar is showing (not editing) a loaded page: its dimmed
    /// subdomain prefix + bold registrable domain, homograph-safe. Nil when there's no usable host.
    private var emphasizedHost: (prefix: String, registrable: String)? {
        let host = !siteHost.isEmpty ? siteHost : URL(string: text)?.host
        guard let host, !host.isEmpty else { return nil }
        return DomainSafety.emphasisSplit(forHost: host)
    }

    /// Show the emphasized domain (instead of the raw URL) when a page is loaded and the bar isn't
    /// being edited — so `apple.com.evil.ru` reads as evil.ru at a glance. Editing reveals the full URL.
    private var showsEmphasizedHost: Bool {
        showingWebContent && !isFocused && !text.isEmpty && emphasizedHost != nil
    }

    /// The editable address field. It is ALWAYS present (never swapped out for a button) so a plain
    /// mouse-down lands on it and focuses it natively. That matters because a focused WKWebView holds
    /// the window's first responder, and SwiftUI's *programmatic* `@FocusState` focus cannot pull key
    /// focus off a live web view — a real click on an NSTextField-backed field can. When a page is
    /// loaded and the bar isn't being edited, the raw URL text is painted `.clear` and the homograph-
    /// safe emphasized host is drawn on top as a non-interactive overlay (see `body`).
    private var addressTextField: some View {
        TextField("Search or enter address", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hide the raw URL under the emphasized-host overlay; show it (with the caret) while editing.
            .foregroundStyle(showsEmphasizedHost ? Color.clear : Color.primary)
            .focused($isFocused)
            // Suppress macOS's native AutoFill/autocomplete (incl. the "AutoFill code from
            // Messages" security-code suggestion) on the search bar. It's a URL/search field, not
            // a code field, so that suggestion is just noise. Our own search suggestions are a
            // separate SwiftUI overlay and are unaffected.
            .disablesAutoFillCompletion()
            .onSubmit {
                onSubmit()
            }
            // Keyboard support for suggestions (arrows/escape) when parent provides hooks.
            .onKeyPress(.downArrow) {
                onSuggestionsArrowDown?()
                return .handled
            }
            .onKeyPress(.upArrow) {
                onSuggestionsArrowUp?()
                return .handled
            }
            .onKeyPress(.escape) {
                onSuggestionsEscape?()
                return .handled
            }
    }

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon

            // The field is always present so clicking it focuses natively (see `addressTextField`).
            // When a page is loaded and not being edited, overlay the homograph-safe emphasized host on
            // top of the (hidden) raw URL. `allowsHitTesting(false)` lets the click fall through to the
            // field, and the whole overlay is non-interactive so focus is never routed through a button.
            addressTextField
                .overlay(alignment: .leading) {
                    if showsEmphasizedHost, let host = emphasizedHost {
                        (Text(host.prefix).foregroundStyle(.secondary)
                            + Text(host.registrable).fontWeight(.semibold).foregroundStyle(.primary))
                            .font(.system(size: fontSize, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                            .accessibilityLabel(Text("Address: \(host.prefix)\(host.registrable)"))
                    }
                }

            if !text.isEmpty && !showsEmphasizedHost {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help("Clear")
                .accessibilityLabel(Text("Clear address"))
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .modifier(AddressBarSurface(
            isDarkHero: isDarkHero,
            isHero: isHero,
            isFocused: isFocused,
            glassEnabled: glassEnabled,
            colorScheme: colorScheme,
            cornerRadius: cornerRadius,
            toolbarMaterial: toolbarMaterial
        ))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    heroBorderColor,
                    lineWidth: isFocused ? (isHero ? 1.15 : 0.9) : (isHero ? 0.65 : 0.5)
                )
        )
        .overlay {
            // The focus gloss is a glass cue, so the dark hero bar (which has no glass) skips it and
            // lets the border carry focus on its own.
            if isHero && isFocused && glassEnabled && !isDarkHero {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        // White gloss reads on dark glass; light mode needs a graphite ring instead.
                        colorScheme == .dark ? Color.white.opacity(0.2) : Color.primary.opacity(0.12),
                        lineWidth: 1.4
                    )
                    .blur(radius: 0.4)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: AdaptiveChrome.shadow(
                colorScheme,
                darkOpacity: isHero ? (isFocused ? 0.16 : 0.1) : (isFocused ? 0.08 : 0.04)
            ),
            radius: isHero ? (isFocused ? 14 : 10) : (isFocused ? 3 : 1),
            x: 0,
            y: isHero ? (isFocused ? 5 : 3) : 1
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .simultaneousGesture(
            TapGesture().onEnded {
                guard isHero else { return }
                focusField()
            },
            including: isHero ? .all : .subviews
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AddressBarHeightPreferenceKey.self, value: proxy.size.height)
                    .preference(
                        key: AddressBarFramePreferenceKey.self,
                        value: isHero ? .zero : proxy.frame(in: .named("mainColumn"))
                    )
            }
        }
        // Track the host window so `focusField()` can resign the web view's first responder.
        .background(WindowAccessor { if hostWindow !== $0 { hostWindow = $0 } })
    }

    /// Moves keyboard focus into the editable field. Critically it first drops any first responder the
    /// embedded WKWebView (or a focused page input, e.g. Stripe's card field) is holding: without that
    /// resign, SwiftUI cannot pull key focus off a live web view, so the bar looks focused but silently
    /// rejects clicks and typing — the "address bar is untouchable once a page is open" bug. The focus
    /// set is deferred one runloop so the emphasized-host label has swapped back to the TextField first.
    private func focusField() {
        _ = hostWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { isFocused = true }
    }

    private var heroBorderColor: Color {
        if isDarkHero {
            // searxly.app's `--hairline` at rest. Focus goes past `--hairline-strong` because the border
            // is now the bar's only focus cue (no gloss, no material shift).
            return Color.white.opacity(isFocused ? 0.24 : 0.10)
        }
        if isHero {
            return AdaptiveChrome.border(
                colorScheme,
                dark: isFocused ? (glassEnabled ? 0.24 : 0.18) : (glassEnabled ? 0.1 : 0.07),
                light: isFocused ? 0.16 : 0.08
            )
        }
        return Color.primary.opacity(isFocused ? 0.12 : 0.06)
    }
}

// MARK: - Bar surface

/// Paints the bar's surface. Everywhere except the dark home hero that means the frosted toolbar
/// material plus Liquid Glass, exactly as before. The dark hero bar instead gets searxly.app's own
/// recipe — the one the Maximum activation gate's key field already uses: a flat white-alpha raise
/// straight onto the black canvas (`--surface-2`), no material and no refraction behind it.
private struct AddressBarSurface: ViewModifier {
    let isDarkHero: Bool
    let isHero: Bool
    let isFocused: Bool
    let glassEnabled: Bool
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat
    let toolbarMaterial: Material

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDarkHero {
            content.background(shape.fill(Color.white.opacity(isFocused ? 0.06 : 0.04)))
        } else {
            content
                .background(toolbarMaterial, in: shape)
                .background {
                    if isHero && glassEnabled {
                        shape.fill(AdaptiveChrome.fill(colorScheme, dark: 0.025, light: 0.018))
                    }
                }
                .searxlyGlass(
                    glassEnabled
                        ? (isHero ? .regular : .interactive)
                        : .clear,
                    in: shape
                )
        }
    }
}

// MARK: - Disable macOS native AutoFill / autocomplete on chrome text fields

extension View {
    /// Turns off macOS's automatic text completion on the AppKit text fields in this view's window.
    /// That completion path is what surfaces the system "AutoFill code from Messages" suggestion (and
    /// other autocomplete chrome) on plain text fields — unwanted on a search/URL bar. No-op off macOS.
    /// The app's own search-suggestion overlay is independent and keeps working.
    func disablesAutoFillCompletion() -> some View {
        background(AutoFillCompletionDisabler().frame(width: 0, height: 0))
    }
}

// MARK: - Resolve the host NSWindow (to resign the web view's first responder before focusing)

/// Reports the `NSWindow` this view lands in. The address bar uses it to resign a live WKWebView's
/// first responder before taking key focus, so clicking the bar works even while a page owns focus.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

private struct AutoFillCompletionDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer until the view is in a window so the field-bearing hierarchy exists; SwiftUI calls this
        // again on focus/text changes, so a momentarily-nil window self-heals on the next pass.
        DispatchQueue.main.async {
            guard let root = nsView.window?.contentView else { return }
            Self.disableCompletion(in: root)
        }
    }

    /// Clears `isAutomaticTextCompletionEnabled` on every NSTextField in the chrome view tree. Web-page
    /// fields live in the WKWebView's own process (not NSTextFields here), so page autofill is untouched.
    private static func disableCompletion(in view: NSView) {
        if let field = view as? NSTextField, field.isAutomaticTextCompletionEnabled {
            field.isAutomaticTextCompletionEnabled = false
        }
        for subview in view.subviews {
            disableCompletion(in: subview)
        }
    }
}
