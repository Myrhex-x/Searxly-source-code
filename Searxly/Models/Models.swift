//
//  Models.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Clean data models for the browser (Phases 6-11)
//

import Foundation
import SwiftUI
import WebKit   // For WKWebView in BrowserTab

// MARK: - SearXNG Instance (Phase 8)

struct SearXNGInstance: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String   // Base URL without trailing slash, e.g. "http://localhost:8080"

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // Convenience for display
    var displayName: String {
        name.isEmpty ? url : name
    }

    // No default public instances.
    // Public instances have been removed: they are unreliable, frequently down,
    // and undermine the privacy goals of Searxly. Users must add their own
    // private/local SearXNG instance (the built-in native instance is easiest).
    static let defaultInstances: [SearXNGInstance] = []

    /// Known public instance base URLs (normalized, no trailing slash).
    /// These are stripped on load and blocked from being added.
    static let publicInstanceURLs: Set<String> = [
        "https://searx.be",
        "https://searx.tiekoetter.com"
    ]

    /// Returns true if the given (normalized) URL is a known public instance.
    static func isPublicInstance(url: String) -> Bool {
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return publicInstanceURLs.contains(normalized)
    }
}

// MARK: - Sidebar Spaces (Phase for advanced organization)

/// Simple fixed set of spaces for organizing tabs.
/// Using the lightweight "tagging + filtering" approach (chosen for Phase 1).
/// Each tab is tagged with a space. The sidebar filters the visible list by the current space.
/// This gives the strong "separate collections" feeling without the complexity of swapping entire tab arrays.
enum Space: String, CaseIterable, Codable, Hashable {
    case personal = "Personal"
    case research = "Research"
    case temporary = "Temporary"

    var systemImage: String {
        switch self {
        case .personal:  return "person"
        case .research:  return "book"
        case .temporary: return "clock"
        }
    }

    /// Short label for collapsed rail / compact UI
    var shortLabel: String {
        switch self {
        case .personal:  return "P"
        case .research:  return "R"
        case .temporary: return "T"
        }
    }
}

// MARK: - Custom Tab Category (user-created sidebar groups)

/// A user-created sidebar category for organizing normal web tabs, in addition to the built-in
/// PINNED / TABS / UTILITIES / TOR groups. Users can create up to `BrowserState.maxCustomCategories`
/// of these. A tab is assigned to a category via `BrowserTab.categoryID`; tabs with no (or an unknown)
/// categoryID fall back into the default "TABS" group.
struct TabCategory: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    /// SF Symbol shown next to the category header. Defaults to a plain folder.
    var systemImage: String

    init(id: UUID = UUID(), name: String, systemImage: String = "folder") {
        self.id = id
        self.name = name
        self.systemImage = systemImage
    }
}

// MARK: - Tab Kind (special non-web tabs + future Governance tab)
// .passwords is the on-device encrypted password vault (in-app special tab).
// .bookmarks (Bookmarks & History) and .downloads are full-page Searxly pages too. All non-web kinds
// are "utility" tabs: grouped under the sidebar "Utilities" category and excluded from hibernation /
// auto-cleanup / navigation by the existing `kind == .web` guards throughout the app.
// (powerHub and holdersCommunity removed — crypto holder / power hub / community features fully excised for general-use focus.)
enum TabKind: String, CaseIterable, Codable, Hashable {
    case web
    case passwords
    case bookmarks
    case downloads
    case extensions
    // case governance   // Planned for future — do not implement yet.

    /// Every non-web kind is an internal full-page Searxly utility page.
    var isUtility: Bool { self != .web }

    /// Sidebar / tab title for utility pages.
    var utilityTitle: String {
        switch self {
        case .web:       return "New Tab"
        case .passwords: return "Passwords"
        case .bookmarks: return "Bookmarks & History"
        case .downloads: return "Downloads"
        case .extensions: return "Extensions"
        }
    }

    /// SF Symbol shown as the tab/sidebar icon for utility pages.
    var utilityIcon: String {
        switch self {
        case .web:       return "globe"
        case .passwords: return "key.fill"
        case .bookmarks: return "bookmark.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        }
    }
}

// MARK: - Browser Tab (Phase 6)

/// @Observable so per-tab UI (sidebar title, mute/pin/hibernation indicators, favicon) updates with
/// fine-grained precision when a single property changes — no more re-diffing the whole `tabs` array via
/// remove/insert "refresh" hacks, and live page titles now reach the sidebar reliably.
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    var title: String = "New Tab"
    var currentURL: URL?

    /// The privacy mode this tab was created with.
    /// Determines whether the underlying WKWebView uses a persistent or ephemeral data store.
    /// For non-web tabs (passwords vault, power hub, etc.) this is ignored — webView is never created.
    let privacyMode: TabPrivacyMode

    /// Which space this tab belongs to. Used for filtering/organization in the sidebar.
    var space: Space = .personal

    /// Distinguishes normal browser tabs from special integrated tabs (e.g. passwords vault, future governance).
    /// Non-.web tabs never own a WKWebView and get special rendering + are excluded from
    /// hibernation and auto-cleanup.
    var kind: TabKind = .web

    /// When true the tab is "pinned" — shown under the PINNED section with a pin indicator. Pinned tabs
    /// can still be closed (via the hover ✕ or the right-click "Close Tab"); pinning is an organization
    /// affordance, not a delete lock.
    var isPinned: Bool = false

    /// Optional custom sidebar category this tab belongs to (see TabCategory). nil = the default "TABS"
    /// group. Only meaningful for normal web tabs: pinned tabs always render under PINNED, onion tabs
    /// under TOR, and utility tabs under UTILITIES regardless of this value.
    var categoryID: UUID? = nil

    /// When true all <video>/<audio> elements on the page are muted. Applied immediately and re-applied on each navigation.
    var isMuted: Bool = false

    /// True while this tab holds media (a <video>/<audio>) mid-playback — either currently playing or
    /// paused partway through. Maintained by the media-state bridge (see WebViewFactory.mediaStateReporterSource)
    /// for whichever tab is active. Tabs with resumable media are exempt from automatic hibernation so that
    /// switching away and back never tears the page down and restarts the video from the beginning (the
    /// reported "leave a YouTube tab, come back, it starts over" bug).
    var hasResumableMedia: Bool = false

    /// Last observed playback position (seconds) of the tab's primary media element. Remembered as a
    /// fallback so a reload that does happen (e.g. waking a tab the user had paused, or a renderer crash)
    /// can resume near where they left off rather than at 0. Updated by the media-state bridge.
    var lastMediaPositionSeconds: Double = 0

    /// Applies or removes the mute state on all media elements in the current page.
    func applyMute() {
        guard kind == .web, let wv = webView else { return }
        let muted = isMuted ? "true" : "false"
        wv.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(m){m.muted=\(muted);});",
            completionHandler: nil
        )
    }

    /// The actual WebKit view for this tab.
    /// Created via WebViewFactory. This can become nil when the tab is hibernated
    /// to save memory (see TabHibernationManager).
    /// Always nil for non-web tabs (kind != .web).
    private(set) var webView: WKWebView?

    /// When true, the tab's web content has been unloaded to reduce memory usage.
    /// The tab can be restored by calling wakeUp() (usually handled by TabHibernationManager).
    private(set) var isHibernated: Bool = false

    /// Native SERP / home entries that WKWebView history does not cover.
    let navigationHistory = TabNavigationHistory()

    /// A security-scoped resource this tab is actively accessing — the local file or folder the user
    /// opened via "Open File…" (NSOpenPanel hands back a sandbox-scoped URL). WebKit reads the HTML and
    /// its sibling assets over the tab's lifetime, so the scope must stay open the whole time the tab is
    /// showing the file; it's released when the tab is closed or deallocated. nil for ordinary web tabs.
    private var securityScopedResource: URL?

    /// Begins (and retains) security-scoped access to a local file/folder for this tab, releasing any
    /// previously held one first (e.g. the tab navigated to a different local file). Safe to call with a
    /// non-scoped URL — it simply won't be retained. Balanced by `releaseSecurityScopedAccess()`/`deinit`.
    func retainSecurityScopedAccess(to url: URL) {
        releaseSecurityScopedAccess()
        if url.startAccessingSecurityScopedResource() {
            securityScopedResource = url
        }
    }

    /// Ends security-scoped access held for this tab, if any. Called on tab close and from `deinit`.
    func releaseSecurityScopedAccess() {
        if let url = securityScopedResource {
            url.stopAccessingSecurityScopedResource()
            securityScopedResource = nil
        }
    }

    deinit {
        securityScopedResource?.stopAccessingSecurityScopedResource()
    }

    /// - Parameter hibernated: When true, a `.web` tab is created as a lazy *stub* — no WKWebView is
    ///   allocated and no page load is started. `currentURL`/`title` are still seeded so the sidebar can
    ///   render it. The tab transparently loads its page the first time it is selected (the existing
    ///   onChange → didSelectTab → wakeUp path). Used by session restore so cold start spins up exactly
    ///   one WebContent process (the foreground tab) instead of one per restored tab.
    init(initialURL: URL? = nil, privacyMode: TabPrivacyMode = .standard, space: Space = .personal, kind: TabKind = .web, hibernated: Bool = false) {
        self.privacyMode = privacyMode
        self.space = space
        self.kind = kind

        // A hibernated stub deliberately allocates no WKWebView. It is woken (webView created + URL
        // loaded) by wakeUp() when the tab is first selected. Only meaningful for .web tabs.
        let startHibernated = hibernated && kind == .web

        if kind == .web && !startHibernated {
            self.webView = WebViewFactory.makeWebView(mode: privacyMode)
        }

        if let url = initialURL, kind == .web {
            currentURL = url
            title = url.host ?? "New Tab"

            if startHibernated {
                // Lazy/deferred: nothing is created or loaded now; wakeUp() does it on first selection.
                isHibernated = true
            } else {
                // Small delay before load for restored / pre-created tabs so that when the
                // representable + container eventually attach, the page has a better chance of
                // seeing a real size on first paint. The container's attach-time multi-pass
                // stabilization + the early fixer script will also fire.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.webView?.load(URLRequest(url: url))
                }
            }
        } else if startHibernated {
            // Blank web tab restored lazily (no URL): keep it a stub until selected.
            isHibernated = true
        } else if kind.isUtility {
            title = kind.utilityTitle
        }
    }

    /// Convenience computed property for UI
    var isPrivate: Bool {
        privacyMode == .privateEphemeral
    }

    /// Best-known page URL for favicons and sidebar display.
    var pageURLString: String {
        if let url = currentURL ?? webView?.url {
            return url.absoluteString
        }
        return ""
    }

    // MARK: - Hibernation Support (used by TabHibernationManager)

    /// Unloads the WKWebView to free memory. The last known URL is preserved so
    /// the tab can be restored later without losing the user's place.
    /// No-op for non-web tabs (special tabs like passwords vault or power hub do not participate in hibernation).
    func hibernate() {
        // Onion (Tor) tabs are never hibernated: dropping the webView would tear down the live Tor
        // session/circuit and leave the tab unable to reload (.onion needs the proxied webView), and
        // onion tabs are ephemeral by design — there's nothing to restore them to.
        guard kind == .web, privacyMode != .onion else { return }
        // Local-file tabs (opened via "Open File…") are never hibernated: waking reloads currentURL, but
        // the security-scoped access grant can't be re-obtained without another user pick, so a woken
        // file tab would fail to read its own file. Keep them resident, like onion tabs.
        guard currentURL?.isFileURL != true else { return }
        // Tabs mid-playback (video/audio playing or paused partway) are kept resident: hibernating would
        // drop the WKWebView and a later wake would reload the page, restarting the video from the start.
        // Keeping the tab alive means switching away and back resumes exactly where the user left off.
        guard !hasResumableMedia else { return }
        guard !isHibernated, let wv = webView else { return }
        isHibernated = true

        // Best-effort: pause any playing media *before* we drop the webView.
        // This is required so that YouTube (and other sites) stop producing audio
        // after the tab is hibernated. Without an explicit pause, the media element
        // can keep its decoder / audio output unit alive in the WebContent process.
        pauseAllMedia(on: wv)

        // Clear delegate + stop to allow clean deallocation and avoid KVO/observer
        // problems when the WebViewRepresentable that was attached to it is later released.
        wv.stopLoading()
        wv.navigationDelegate = nil
        webView = nil
    }

    /// Public entry point used by BrowserState.closeTab (and any future explicit close paths).
    /// Pauses media on the live webView (if present) and then does the normal hibernate teardown.
    /// We keep this separate from hibernate() so callers that just want to close (not hibernate for later wake)
    /// still get the pause.
    func pauseAllMediaForClose() {
        guard kind == .web, let wv = webView else { return }
        pauseAllMedia(on: wv)
        // Also stop loading immediately; this aborts any in-flight network that might be feeding the player.
        wv.stopLoading()
    }

    /// Pauses every <video> and <audio> element and tries to detach their sources.
    /// Additionally navigates the webview to a blank document. This is the reliable way to
    /// force WebKit to tear down the media pipeline / audio output units / MSE decoders for
    /// difficult players (YouTube in particular often keeps audio running via internal contexts
    /// even after a simple .pause() on the visible <video>).
    /// Called on hibernate and (via closeTab) on explicit close so background audio stops.
    private func pauseAllMedia(on wv: WKWebView) {
        let js = """
        (function(){
          try {
            const els = document.querySelectorAll('video, audio');
            els.forEach(function(el){
              try { el.pause(); } catch(e){}
              // Detach src when possible (helps release some decoders; safe for most players).
              try {
                if (el.src) {
                  el.src = '';
                  el.load();
                }
                // Also clear srcObject if set (MSE / blob cases).
                if (el.srcObject) {
                  el.srcObject = null;
                }
              } catch(e){}
            });
            // YouTube-specific best effort: if the player is accessible, try to stop it.
            try {
              const player = document.querySelector('ytd-player') || document.querySelector('#player');
              if (player && typeof player.stopVideo === 'function') { player.stopVideo(); }
            } catch(e){}
          } catch(e){}
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)

        // Strong teardown: navigate to a minimal blank page. This causes the WebContent process
        // to unload the previous document's media elements, release audio sessions, and drop
        // any lingering RBS "WebKit Media Playback" assertions for this webview.
        // Do it shortly after the JS so the pause has a chance to run first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak wv] in
            wv?.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        }
    }

    /// Recreates the WKWebView (using the original privacy mode) and reloads the
    /// last known URL if one exists.
    /// No-op for non-web tabs.
    @MainActor
    func wakeUp() {
        guard kind == .web else { return }
        guard isHibernated || webView == nil else { return }

        let newWebView = WebViewFactory.makeWebView(mode: privacyMode)
        self.webView = newWebView
        isHibernated = false

        if let url = currentURL {
            // If this is a YouTube video the user had partway through, resume near that spot on reload
            // instead of at 0 (a paused video's tab can still be hibernated, and process crashes reload
            // too). Non-YouTube URLs are loaded unchanged.
            let loadURL = Self.youTubeResumeURL(url, at: lastMediaPositionSeconds)
            // Tiny delay so the new webview (created for wake) has a chance to be hosted
            // with real bounds before the page's first paint/JS measurements. The attach
            // stabilization passes will also fire when the representable appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak newWebView] in
                newWebView?.load(URLRequest(url: loadURL))
            }
        }

        // Layout stabilization for the fresh webview is driven automatically by:
        // - WebViewFactory (the LayoutFixer user script at documentStart)
        // - WebViewRepresentable (didCommit / didFinish + requestStabilization)
        // - WebViewContainer (layout() + viewDidMoveToWindow + explicit stabilizeLayout())
        // No extra work needed here; the representable will be re-attached via .id(tab) in ContentView.
    }

    /// If `url` is a YouTube watch/short/live link and `seconds` is a meaningful position, returns the URL
    /// with a `t=<seconds>` parameter so a reload resumes near where the user left off. Any pre-existing
    /// `t`/`start` param is replaced. Returns `url` unchanged for non-YouTube URLs or trivial positions.
    static func youTubeResumeURL(_ url: URL, at seconds: Double) -> URL {
        guard seconds > 5, seconds.isFinite else { return url }
        let host = url.host?.lowercased() ?? ""
        let isYouTube = host.contains("youtube.com") || host.contains("youtu.be")
        guard isYouTube else { return url }
        let path = url.path.lowercased()
        let isVideoPage = host.contains("youtu.be")
            || path.hasPrefix("/watch") || path.hasPrefix("/shorts") || path.hasPrefix("/live")
        guard isVideoPage else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "t" || $0.name == "start" }
        items.append(URLQueryItem(name: "t", value: String(Int(seconds))))
        comps.queryItems = items
        return comps.url ?? url
    }
}

// MARK: - Tab Snapshot for Session Restoration (privacy-preserving)
// Lightweight Codable record so we can restore tabs with their original privacyMode + kind.
// BrowserTab itself cannot be serialized because it owns a WKWebView (for .web tabs).
struct TabSnapshot: Codable, Equatable {
    let url: String
    let privacyMode: TabPrivacyMode
    let space: Space
    let kind: TabKind
    var isPinned: Bool
    /// Custom sidebar category assignment (see TabCategory). nil = default "TABS" group.
    var categoryID: UUID?

    init(url: String, privacyMode: TabPrivacyMode, space: Space = .personal, kind: TabKind = .web, isPinned: Bool = false, categoryID: UUID? = nil) {
        self.url = url
        self.privacyMode = privacyMode
        self.space = space
        self.kind = kind
        self.isPinned = isPinned
        self.categoryID = categoryID
    }

    // Custom decoding so old AppData.json files (without kind/space/isPinned/categoryID) still load correctly.
    private enum CodingKeys: String, CodingKey {
        case url, privacyMode, space, kind, isPinned, categoryID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        privacyMode = try container.decode(TabPrivacyMode.self, forKey: .privacyMode)
        space = try container.decodeIfPresent(Space.self, forKey: .space) ?? .personal
        kind = try container.decodeIfPresent(TabKind.self, forKey: .kind) ?? .web
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
    }
}



// MARK: - Download Item (Phase 9)

struct DownloadItem: Identifiable, Equatable {
    let id = UUID()
    let suggestedFilename: String
    // var, not let: "Keep" (amnesic sessions) moves the file to ~/Downloads and repoints this.
    var destinationURL: URL?
    var progress: Double = 0.0
    var isComplete: Bool = false
    var error: String?
    let startDate = Date()

    /// Amnesic sessions: true while the file sits in the wiped-on-quit session folder. "Keep"
    /// moves it to ~/Downloads and flips this off.
    var isSessionOnly: Bool {
        guard AmnesiaMode.isActive, let url = destinationURL else { return false }
        return url.path.hasPrefix(AmnesiaMode.sessionDownloadsDirectory.path)
    }

    var statusText: String {
        if let error { return "Failed: \(error)" }
        if isComplete { return isSessionOnly ? "Complete — gone on quit unless kept" : "Complete" }
        return String(format: "%.0f%%", progress * 100)
    }
}

// MARK: - History & Bookmark Items (Phase 7+)

struct HistoryItem: Identifiable, Codable, Equatable {
    let id = UUID()
    let url: String
    let title: String
    let date: Date

    init(url: String, title: String, date: Date = Date()) {
        self.url = url
        self.title = title
        self.date = date
    }

    // id is a pure UI identity (Identifiable). We do not persist it; a fresh UUID is
    // assigned on every load/restore. Explicit CodingKeys silences the "will not be decoded"
    // warning and makes the intent clear.
    private enum CodingKeys: String, CodingKey {
        case url, title, date
    }
}

struct BookmarkItem: Identifiable, Codable, Equatable {
    let id = UUID()
    let url: String
    let title: String
    let dateAdded: Date
    /// Optional user or AI-provided note for the bookmark (e.g. from Local AI "bookmark_with_note" tool).
    /// Safe addition: old persisted data decodes with nil via decodeIfPresent.
    let note: String?

    init(url: String, title: String, dateAdded: Date = Date(), note: String? = nil) {
        self.url = url
        self.title = title
        self.dateAdded = dateAdded
        self.note = note
    }

    // id is a pure UI identity (Identifiable). We do not persist it.
    private enum CodingKeys: String, CodingKey {
        case url, title, dateAdded, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - Password Vault Entry (metadata only)
// Actual secrets are stored exclusively in the Keychain (PasswordVaultSecureStore)
// with userPresence protection. This struct is only for titles, usernames, notes, etc.
// and participates in AppData encryption + backups.
struct PasswordVaultEntry: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var domain: String          // normalized host or domain (e.g. "example.com")
    var username: String
    var notes: String?
    var dateAdded: Date
    var lastUsed: Date?

    /// Whether this login also carries a TOTP (2FA) seed. The seed itself lives in the Keychain —
    /// only this presence flag is persisted here, so the vault list can render a 2FA badge without
    /// a Keychain round-trip per row.
    var hasTOTP: Bool

    init(id: UUID = UUID(), domain: String, username: String, notes: String? = nil, dateAdded: Date = Date(), lastUsed: Date? = nil, hasTOTP: Bool = false) {
        self.id = id
        self.domain = domain
        self.username = username
        self.notes = notes
        self.dateAdded = dateAdded
        self.lastUsed = lastUsed
        self.hasTOTP = hasTOTP
    }

    /// Hand-written decode. Swift's synthesized `init(from:)` IGNORES property default values and
    /// throws `keyNotFound` for any missing key — and `PasswordVaultStore` decodes entries
    /// element-by-element, silently DROPPING any that throw. So a synthesized decoder plus a new
    /// non-optional field would erase every pre-existing login the first time the file is read.
    /// Decoding each field defensively means new fields can be added without that risk.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Identity fields stay strict: an entry without an id/domain/username is not repairable,
        // and dropping it is better than surfacing a blank row that maps to a real Keychain secret.
        id = try c.decode(UUID.self, forKey: .id)
        domain = try c.decode(String.self, forKey: .domain)
        username = try c.decode(String.self, forKey: .username)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil
        dateAdded = (try? c.decodeIfPresent(Date.self, forKey: .dateAdded)) ?? nil ?? Date()
        lastUsed = (try? c.decodeIfPresent(Date.self, forKey: .lastUsed)) ?? nil
        hasTOTP = (try? c.decodeIfPresent(Bool.self, forKey: .hasTOTP)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, domain, username, notes, dateAdded, lastUsed, hasTOTP
    }
}

// MARK: - Simple Download Manager (Phase 9)

@MainActor
@Observable
final class DownloadsManager {
    static let shared = DownloadsManager()

    private(set) var downloads: [DownloadItem] = []

    private init() {}

    func addDownload(suggestedFilename: String, destination: URL? = nil) -> DownloadItem {
        let item = DownloadItem(suggestedFilename: suggestedFilename, destinationURL: destination)
        downloads.insert(item, at: 0)
        return item
    }

    func updateProgress(for id: UUID, progress: Double) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].progress = progress
        }
    }

    func completeDownload(id: UUID, success: Bool = true, error: String? = nil) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].isComplete = success
            downloads[index].error = error
            downloads[index].progress = success ? 1.0 : downloads[index].progress
        }
    }

    func removeDownload(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
    }

    /// Amnesic sessions: move a session-only download into ~/Downloads so it survives quitting.
    /// Returns false when the move failed (file already gone, disk full) — the item stays session-only.
    func keepPermanently(id: UUID) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].isSessionOnly,
              let source = downloads[index].destinationURL else { return false }
        let destination = DownloadBridge.uniquePermanentURL(for: source.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            downloads[index].destinationURL = destination
            return true
        } catch {
            return false
        }
    }

    func clearCompleted() {
        downloads.removeAll { $0.isComplete && $0.error == nil }
    }
}

// MARK: - Tab Layout (UI preference)
// Sidebar (left rail, Arc-style) is now the ONLY supported layout.
// The enum + raw string are kept only for legacy/unwired views (RootContainerView, TopBarArea).
// Active UI in ContentView (now thin, state in BrowserState) always uses the sidebar path.
// Updated during monster views refactor (2026).
enum TabLayout: String, CaseIterable {
    case sidebar
    case horizontal   // deprecated / no longer offered
}

// MARK: - Appearance / Theme
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.stars.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Match Mac"
        case .light:  return "Always light"
        case .dark:   return "Always dark"
        }
    }
}

// MARK: - App Notifications (custom in-app + system notification system)
// Used for surfacing web / external notifications (e.g. from X, other sites) fluidly inside the browser UI
// with full liquid glass when the user is actively viewing web content. Falls back to macOS
// UNUserNotificationCenter banners when not "looking at the browser".
struct AppNotification: Identifiable, Equatable, Hashable {
    let id = UUID()
    let title: String
    let body: String
    let source: String          // e.g. "X" or "x.com"
    let iconSystemName: String  // SF Symbol for the left icon
    let date: Date = .now
}

// MARK: - TabSnapshot + BrowserTab extensions (moved to EOF to guarantee file scope after edits)
extension TabSnapshot {
    init(from tab: BrowserTab) {
        self.url = tab.currentURL?.absoluteString ?? ""
        self.privacyMode = tab.privacyMode
        self.space = tab.space
        self.kind = tab.kind
        self.isPinned = tab.isPinned
        self.categoryID = tab.categoryID
    }
}

extension BrowserTab {
    /// Creates a BrowserTab from a persisted snapshot.
    /// For non-web tabs (e.g. passwords vault) the webView is never allocated (see init).
    /// - Parameter hibernated: When true, `.web` tabs are restored as lazy stubs (no WKWebView / no load
    ///   until first selected). Utility tabs ignore this — they never own a WKWebView anyway.
    convenience init(from snapshot: TabSnapshot, hibernated: Bool = false) {
        if snapshot.kind.isUtility {
            self.init(
                privacyMode: snapshot.privacyMode,
                space: snapshot.space,
                kind: snapshot.kind
            )
            // title is set by the kind-aware init
        } else {
            // Web tab (or unknown/removed future kind treated as web for safety).
            // (powerHub and holdersCommunity kinds were removed; old snapshots fall back here gracefully.)
            let url = URL(string: snapshot.url)
            self.init(
                initialURL: url,
                privacyMode: snapshot.privacyMode,
                space: snapshot.space,
                kind: .web,
                hibernated: hibernated
            )
        }
        self.isPinned = snapshot.isPinned
        self.categoryID = snapshot.categoryID
    }
}