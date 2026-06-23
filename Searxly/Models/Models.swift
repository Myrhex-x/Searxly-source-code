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

// MARK: - Tab Kind (special non-web tabs + future Governance tab)
// .passwords is the on-device encrypted password vault (in-app special tab).
// (powerHub and holdersCommunity removed — crypto holder / power hub / community features fully excised for general-use focus.)
enum TabKind: String, CaseIterable, Codable, Hashable {
    case web
    case passwords
    // case governance   // Planned for future — do not implement yet.
}

// The scaffolding (kind checks, content switch in ContentView, sidebar icon special-case, non-hibernation
// guards) is intentionally designed to support it with minimal extra work. (passwords is the only remaining special non-web tab).

// MARK: - Browser Tab (Phase 6)

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

    /// When true the tab is "pinned" — shown with a visual indicator and protected from accidental close.
    var isPinned: Bool = false

    /// When true all <video>/<audio> elements on the page are muted. Applied immediately and re-applied on each navigation.
    var isMuted: Bool = false

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

    init(initialURL: URL? = nil, privacyMode: TabPrivacyMode = .standard, space: Space = .personal, kind: TabKind = .web) {
        self.privacyMode = privacyMode
        self.space = space
        self.kind = kind

        if kind == .web {
            self.webView = WebViewFactory.makeWebView(mode: privacyMode)
        }

        if let url = initialURL, kind == .web {
            // Small delay before load for restored / pre-created tabs so that when the
            // representable + container eventually attach, the page has a better chance of
            // seeing a real size on first paint. The container's attach-time multi-pass
            // stabilization + the early fixer script will also fire.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.webView?.load(URLRequest(url: url))
            }
            currentURL = url
            title = url.host ?? "New Tab"
        } else if kind == .passwords {
            title = "Passwords"
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
        guard kind == .web else { return }
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
            // Tiny delay so the new webview (created for wake) has a chance to be hosted
            // with real bounds before the page's first paint/JS measurements. The attach
            // stabilization passes will also fire when the representable appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak newWebView] in
                newWebView?.load(URLRequest(url: url))
            }
        }

        // Layout stabilization for the fresh webview is driven automatically by:
        // - WebViewFactory (the LayoutFixer user script at documentStart)
        // - WebViewRepresentable (didCommit / didFinish + requestStabilization)
        // - WebViewContainer (layout() + viewDidMoveToWindow + explicit stabilizeLayout())
        // No extra work needed here; the representable will be re-attached via .id(tab) in ContentView.
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

    init(url: String, privacyMode: TabPrivacyMode, space: Space = .personal, kind: TabKind = .web, isPinned: Bool = false) {
        self.url = url
        self.privacyMode = privacyMode
        self.space = space
        self.kind = kind
        self.isPinned = isPinned
    }

    // Custom decoding so old AppData.json files (without kind/space/isPinned) still load correctly.
    private enum CodingKeys: String, CodingKey {
        case url, privacyMode, space, kind, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        privacyMode = try container.decode(TabPrivacyMode.self, forKey: .privacyMode)
        space = try container.decodeIfPresent(Space.self, forKey: .space) ?? .personal
        kind = try container.decodeIfPresent(TabKind.self, forKey: .kind) ?? .web
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}



// MARK: - Download Item (Phase 9)

struct DownloadItem: Identifiable, Equatable {
    let id = UUID()
    let suggestedFilename: String
    let destinationURL: URL?
    var progress: Double = 0.0
    var isComplete: Bool = false
    var error: String?
    let startDate = Date()

    var statusText: String {
        if let error { return "Failed: \(error)" }
        if isComplete { return "Complete" }
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

    init(id: UUID = UUID(), domain: String, username: String, notes: String? = nil, dateAdded: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.domain = domain
        self.username = username
        self.notes = notes
        self.dateAdded = dateAdded
        self.lastUsed = lastUsed
    }
}

// MARK: - Simple Download Manager (Phase 9)

@MainActor
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
    }
}

extension BrowserTab {
    /// Creates a BrowserTab from a persisted snapshot.
    /// For non-web tabs (e.g. passwords vault) the webView is never allocated (see init).
    convenience init(from snapshot: TabSnapshot) {
        if snapshot.kind == .passwords {
            self.init(
                privacyMode: snapshot.privacyMode,
                space: snapshot.space,
                kind: .passwords
            )
            // title is set to "Passwords" inside the kind-aware init
        } else {
            // Web tab (or unknown/removed future kind treated as web for safety).
            // (powerHub and holdersCommunity kinds were removed; old snapshots fall back here gracefully.)
            let url = URL(string: snapshot.url)
            self.init(
                initialURL: url,
                privacyMode: snapshot.privacyMode,
                space: snapshot.space,
                kind: .web
            )
        }
        self.isPinned = snapshot.isPinned
    }
}