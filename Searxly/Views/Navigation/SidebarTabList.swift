//
//  SidebarTabList.swift
//  Searxly
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct SidebarTabList: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Wallet is an opt-in surface — hidden for fresh installs until enabled in Settings → Wallet.
    @AppStorage(WalletConfig.Keys.surfaceEnabled) private var walletSurfaceEnabled = WalletConfig.surfaceEnabledDefault

    @Binding var tabs: [BrowserTab]
    @Binding var selectedTabID: UUID?

    @State private var hoveredTabID: UUID? = nil

    // Category create / rename alert.
    @State private var showingCategoryEditor = false
    @State private var renameTarget: TabCategory? = nil   // nil while creating a new category
    @State private var categoryNameDraft = ""
    /// When creating a category from a tab's "Move to Category ▸ New Category…" menu, the tab to drop
    /// into the freshly created category. nil when creating from the generic "New Category" button.
    @State private var pendingCategoryTab: BrowserTab? = nil
    /// Header currently highlighted as a drag drop-target ("TABS" sentinel or a category id string).
    @State private var dropTargetHeaderID: String? = nil

    let glassEnabled: Bool
    let toolbarMaterial: Material
    /// Floating-sidebar appearance (Settings → Appearance): the list renders with NO opaque canvas of
    /// its own so the rounded glass card behind it (FloatingSidebarChrome) shows through.
    var isFloating: Bool = false
    let sidebarWidth: CGFloat
    let isCollapsed: Bool
    let toggleCollapse: () -> Void

    let newTabAction: () -> Void
    let newPrivateTabAction: () -> Void
    let closeTabAction: (BrowserTab) -> Void
    let closeAllTabsAction: () -> Void
    let pinTabAction: (BrowserTab) -> Void
    let duplicateTabAction: (BrowserTab) -> Void
    let muteTabAction: (BrowserTab) -> Void
    let forgetDomainAction: (String) -> Void
    let reopenClosedTabAction: (() -> Void)?
    let hasClosedTabs: Bool

    /// Bookmark a specific tab (sidebar right-click → "Bookmark Tab").
    let bookmarkTabAction: (BrowserTab) -> Void

    // MARK: Custom sidebar categories
    let customCategories: [TabCategory]
    /// False once the user has reached `BrowserState.maxCustomCategories`.
    let canAddCategory: Bool
    /// Append a tab into a category (nil = the default "TABS" group). Used by the context menu and by
    /// dropping a tab onto a category header.
    let moveTabToCategory: (BrowserTab, UUID?) -> Void
    /// Reorder `first` to sit just before `second` (used when a tab is dropped onto another tab row).
    let reorderTabBefore: (BrowserTab, BrowserTab) -> Void
    /// Creates a category and, when a tab is supplied, immediately moves it into the new category.
    let addCategoryAction: (String, BrowserTab?) -> Void
    let renameCategoryAction: (TabCategory, String) -> Void
    let deleteCategoryAction: (TabCategory) -> Void

    // Bookmarks shown as a collapsible section in the sidebar (Arc-style).
    let bookmarks: [BookmarkItem]
    let onOpenBookmark: (BookmarkItem) -> Void
    let onRemoveBookmark: (BookmarkItem) -> Void
    @State private var isBookmarksExpanded = true
    /// Most-recent bookmarks shown inline; the rest live in the full Bookmarks & History page.
    private let sidebarBookmarkLimit = 15

    @Binding var showingSettings: Bool
    @Binding var showingWallet: Bool
    @Binding var showingBookmarks: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingDownloads: Bool

    @State private var isSettingsHovered = false
    @State private var isWalletHovered = false
    @State private var isDownloadsHovered = false
    @State private var isNewCategoryHovered = false
    /// Which collapsed-rail top control (keyed by SF Symbol name) is currently hovered.
    @State private var hoveredRailControl: String? = nil

    private var pinnedTabs: [BrowserTab] { tabs.filter { $0.isPinned } }
    private var regularTabs: [BrowserTab] { tabs.filter { !$0.isPinned } }
    /// Non-pinned standard web tabs (not a Tor / onion tab, not an internal utility page).
    private var normalTabs: [BrowserTab] { regularTabs.filter { $0.privacyMode != .onion && !$0.kind.isUtility } }
    /// Non-pinned onion (Tor) tabs — grouped under their own "Tor" section in the sidebar.
    private var onionTabs: [BrowserTab] { regularTabs.filter { $0.privacyMode == .onion } }
    /// Non-pinned internal full-page pages (Passwords, Bookmarks & History, Downloads) — grouped under
    /// their own "Utilities" section, which appears only while one is open (just like the Tor section).
    private var utilityTabs: [BrowserTab] { regularTabs.filter { $0.kind.isUtility } }

    /// Custom-category ids that still exist (used to fall stale assignments back to "TABS").
    private var validCategoryIDs: Set<UUID> { Set(customCategories.map { $0.id }) }
    /// Non-pinned normal web tabs with no (or an unknown) category — the default "TABS" group.
    private var uncategorizedTabs: [BrowserTab] {
        normalTabs.filter { $0.categoryID == nil || !validCategoryIDs.contains($0.categoryID!) }
    }
    private func tabs(in category: TabCategory) -> [BrowserTab] {
        normalTabs.filter { $0.categoryID == category.id }
    }
    /// The TABS header (and its drop target) shows whenever there's another group to distinguish it from.
    private var shouldShowTabsHeader: Bool {
        !pinnedTabs.isEmpty || !onionTabs.isEmpty || !utilityTabs.isEmpty || !customCategories.isEmpty
    }

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

            if SoftwareUpdater.shared.updateAvailable {
                SidebarUpdateButton(isCollapsed: isCollapsed,
                                    version: SoftwareUpdater.shared.latestVersion) {
                    SoftwareUpdater.shared.presentUpdate()
                }
                .padding(.horizontal, isCollapsed ? 6 : 10)
                .padding(.top, 4)
                .transition(.opacity)
            }

            if !isCollapsed {
                if canAddCategory {
                    sidebarNewCategoryButton
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }

                SidebarDeleteAllTabsButton(action: closeAllTabsAction)
                    .padding(.horizontal, 10)
                    .padding(.top, canAddCategory ? 2 : 4)

                if TabHibernationManager.shared.isEnabled {
                    hibernationTimerIndicator
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }

            bottomFooter
            if walletSurfaceEnabled {
                walletButton
            }
            settingsButton
        }
        .background {
            // Floating style: stay transparent — the frosted card (FloatingSidebarChrome) is the
            // surface. Classic style: the sidebar IS the app canvas, edge to edge.
            if !isFloating {
                Rectangle()
                    .fill(AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled))
            }
        }
        .alert(
            renameTarget == nil ? "New Category" : "Rename Category",
            isPresented: $showingCategoryEditor
        ) {
            TextField("Category name", text: $categoryNameDraft)
            Button("Cancel", role: .cancel) {
                categoryNameDraft = ""
                pendingCategoryTab = nil
            }
            Button(renameTarget == nil ? "Create" : "Rename") {
                let name = categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let movingTab = pendingCategoryTab
                categoryNameDraft = ""
                pendingCategoryTab = nil
                guard !name.isEmpty else { return }
                if let target = renameTarget {
                    renameCategoryAction(target, name)
                } else {
                    addCategoryAction(name, movingTab)
                }
            }
        } message: {
            Text(renameTarget == nil
                 ? "Group tabs under a name of your choice. Drag tabs onto it, or use the tab's right-click menu."
                 : "Choose a new name for this category.")
        }
    }

    /// Opens the alert to create a brand-new category. When `tab` is supplied, that tab is moved into
    /// the new category as soon as it's created.
    private func beginCreateCategory(moving tab: BrowserTab? = nil) {
        pendingCategoryTab = tab
        renameTarget = nil
        categoryNameDraft = ""
        showingCategoryEditor = true
    }

    /// Opens the alert pre-filled to rename an existing category.
    private func beginRenameCategory(_ category: TabCategory) {
        renameTarget = category
        categoryNameDraft = category.name
        showingCategoryEditor = true
    }

    // MARK: - Expanded tab list

    // NOTE: We deliberately do NOT use SwiftUI `Section { } header: { }` here. On macOS the section
    // header draws a hairline separator beneath itself that ignores .listRowSeparator/.listSectionSeparator
    // hiding — that was the stray "line under TABS". Rendering each header as an ordinary list row (which
    // reliably honors .listRowSeparator(.hidden)) removes it entirely.
    //
    // Reordering + categorizing use explicit drag-and-drop (.draggable on rows, .dropDestination on rows
    // and on group headers) rather than List.onMove, because onMove only reorders within one ForEach and
    // could not move a tab between groups (and was unreliable with the tappable rows). Dropping a tab onto
    // another row reorders it (adopting that row's category); dropping onto a header moves it into that group.
    private var expandedTabList: some View {
        List {
            // Pinned group
            if !pinnedTabs.isEmpty {
                sectionHeader("PINNED", systemImage: "pin.fill", tint: .primary)
                ForEach(pinnedTabs) { tab in
                    draggableTabRow(tab)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.05))
                                .padding(.horizontal, 4)
                        )
                        .listRowSeparator(.hidden)
                }
            }

            // Default "TABS" group (uncategorized normal web tabs). The header shows (and acts as a drop
            // target back to "no category") whenever there's another group to distinguish it from.
            if shouldShowTabsHeader {
                tabsHeaderRow
            }
            ForEach(uncategorizedTabs) { tab in
                draggableTabRow(tab)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // User-created categories. Each header is a drop target and is shown even when empty so tabs
            // can be dragged into it.
            ForEach(customCategories) { category in
                categoryHeaderRow(category)
                let categorized = tabs(in: category)
                if categorized.isEmpty {
                    emptyCategoryPlaceholder(category)
                } else {
                    ForEach(categorized) { tab in
                        draggableTabRow(tab)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }

            // Utilities (internal full-page Searxly pages) — appear only when one is open.
            if !utilityTabs.isEmpty {
                sectionHeader("UTILITIES", systemImage: "square.grid.2x2.fill")
                ForEach(utilityTabs) { tab in
                    tabRow(tab)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            // Tor (onion) tabs — their own clearly separated group.
            if !onionTabs.isEmpty {
                sectionHeader("TOR", systemImage: "point.3.connected.trianglepath.dotted")
                ForEach(onionTabs) { tab in
                    tabRow(tab)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            // Bookmarks — collapsible group listing the most recent saved bookmarks.
            if !bookmarks.isEmpty {
                bookmarksHeaderRow
                if isBookmarksExpanded {
                    ForEach(bookmarks.prefix(sidebarBookmarkLimit)) { bookmark in
                        bookmarkRow(bookmark)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    if bookmarks.count > sidebarBookmarkLimit {
                        showAllBookmarksRow
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .padding(.top, 4)
    }

    /// Collapsible BOOKMARKS header rendered as an ordinary list row (not a Section header) so it carries
    /// no separator. The chevron on the right reflects/toggles the expanded state.
    private var bookmarksHeaderRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isBookmarksExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 13, alignment: .center)
                Text("BOOKMARKS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isBookmarksExpanded ? 0 : -90))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Drag & drop (reorder + categorize)

    /// A tab row that can be dragged (to reorder, or to move between groups) and is itself a drop target
    /// (dropping another tab onto it inserts that tab just before this one, adopting this row's category).
    ///
    /// Uses the AppKit-backed `.onDrag`/`.onDrop` pair rather than `.draggable`/`.dropDestination`: the
    /// latter would not reliably start a drag from these tappable List rows. The drag carries the tab's
    /// UUID as plain text; drop handlers resolve it back to the live tab and ignore anything else.
    @ViewBuilder
    private func draggableTabRow(_ tab: BrowserTab) -> some View {
        tabRow(tab)
            .onDrag {
                NSItemProvider(object: tab.id.uuidString as NSString)
            } preview: {
                // A clean, opaque, monochrome pill. Without an explicit preview, macOS snapshots the whole
                // row — including its selection/hover tint — which read as a blue "duplicate" while dragging.
                tabDragPreview(tab)
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleProviderDrop(providers) { dragged in
                    reorderTabBefore(dragged, tab)
                }
            }
    }

    /// Compact monochrome drag image shown under the cursor while dragging a tab.
    private func tabDragPreview(_ tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            if tab.kind.isUtility {
                Image(systemName: tab.kind.utilityIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                FaviconView(pageURL: tab.pageURLString, size: 16, cornerRadius: 4, loadRemote: !tab.isPrivate)
            }
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 220, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.18), lineWidth: 0.5)
                )
        }
    }

    private func tabByID(_ idString: String) -> BrowserTab? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return tabs.first { $0.id == uuid }
    }

    /// Resolves the dragged tab's UUID from a dropped item provider (async) and runs `action` for it on
    /// the main actor. Returns true synchronously so the drop is accepted; non-tab payloads are ignored.
    private func handleProviderDrop(_ providers: [NSItemProvider], _ action: @escaping (BrowserTab) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idString = object as? String else { return }
            Task { @MainActor in
                if let dragged = tabByID(idString) { action(dragged) }
            }
        }
        return true
    }

    /// Drop a tab into a category (nil = the default "TABS" group). Pinned tabs are excluded (unpin first).
    private func dropTab(intoCategory categoryID: UUID?, _ providers: [NSItemProvider]) -> Bool {
        handleProviderDrop(providers) { dragged in
            guard !dragged.isPinned else { return }
            moveTabToCategory(dragged, categoryID)
        }
    }

    private func headerDropHighlight(for headerID: String) -> some View {
        // Monochrome (white-ish) drop highlight — per brand, no blue accent.
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(dropTargetHeaderID == headerID ? 0.12 : 0))
            .padding(.horizontal, 6)
    }

    /// Two-way binding for a header's drop highlight, used as `.onDrop(isTargeted:)`.
    private func headerDropBinding(_ headerID: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetHeaderID == headerID },
            set: { isIn in
                if isIn { dropTargetHeaderID = headerID }
                else if dropTargetHeaderID == headerID { dropTargetHeaderID = nil }
            }
        )
    }

    // MARK: - Group headers (drop targets) + category controls

    /// Default "TABS" group header — a drop target that moves a dropped tab out of any category.
    private var tabsHeaderRow: some View {
        sectionHeaderLabel("TABS", systemImage: "square.on.square")
            .background(headerDropHighlight(for: "TABS"))
            .onDrop(of: [.text], isTargeted: headerDropBinding("TABS")) { providers in
                dropTab(intoCategory: nil, providers)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// A custom-category header — a drop target, plus a right-click menu to rename or delete it.
    private func categoryHeaderRow(_ category: TabCategory) -> some View {
        let headerID = category.id.uuidString
        return sectionHeaderLabel(category.name, systemImage: category.systemImage)
            .background(headerDropHighlight(for: headerID))
            .contentShape(Rectangle())
            .contextMenu {
                Button { beginRenameCategory(category) } label: {
                    Label("Rename Category", systemImage: "pencil")
                }
                Button(role: .destructive) { deleteCategoryAction(category) } label: {
                    Label("Delete Category", systemImage: "trash")
                }
            }
            .onDrop(of: [.text], isTargeted: headerDropBinding(headerID)) { providers in
                dropTab(intoCategory: category.id, providers)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// Placeholder row for an empty category — also a drop target so the category is usable when empty.
    private func emptyCategoryPlaceholder(_ category: TabCategory) -> some View {
        Text("Drag tabs here")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 5)
            .padding(.leading, 33)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(headerDropHighlight(for: category.id.uuidString))
            .onDrop(of: [.text], isTargeted: headerDropBinding(category.id.uuidString)) { providers in
                dropTab(intoCategory: category.id, providers)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// "New Category" affordance shown (below the cap) in the lower sidebar, just above "Delete all tabs".
    /// Styled to match SidebarDeleteAllTabsButton's compact, subtle look.
    private var sidebarNewCategoryButton: some View {
        Button {
            beginCreateCategory()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("New Category")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 3)
            .background(
                isNewCategoryHovered
                    ? AdaptiveChrome.fill(colorScheme, dark: 0.06)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async { isNewCategoryHovered = hovering }
        }
        .help("Create a tab category (up to \(BrowserState.maxCustomCategories))")
    }

    // MARK: - Bookmark rows (sidebar Bookmarks section)

    private func bookmarkRow(_ bookmark: BookmarkItem) -> some View {
        Button {
            onOpenBookmark(bookmark)
        } label: {
            HStack(spacing: 8) {
                FaviconView(pageURL: bookmark.url, size: 16, cornerRadius: 4)
                Text(bookmarkDisplayTitle(bookmark))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(bookmark.url)
        .contextMenu {
            Button("Open") { onOpenBookmark(bookmark) }
            Divider()
            Button("Remove from Bookmarks", role: .destructive) { onRemoveBookmark(bookmark) }
        }
    }

    private func bookmarkDisplayTitle(_ bookmark: BookmarkItem) -> String {
        if !bookmark.title.isEmpty { return bookmark.title }
        return URL(string: bookmark.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? bookmark.url
    }

    private var showAllBookmarksRow: some View {
        Button {
            showingBookmarks = true   // opens the full Bookmarks & History utility page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Show all (\(bookmarks.count))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The styled label for a sidebar group header (PINNED / TABS / UTILITIES / TOR / BOOKMARKS / custom
    /// categories). The leading icon sits under the row favicons (≈14pt) so headers and rows line up, and
    /// they all share the same weight/tracking/color. No list-row modifiers — callers add those (and any
    /// drop target / context menu) so the same label can back both plain and interactive headers.
    private func sectionHeaderLabel(_ title: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 13, alignment: .center)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One consistent section header rendered as an ordinary (non-interactive) list row.
    private func sectionHeader(_ title: String, systemImage: String, tint: Color = .secondary) -> some View {
        sectionHeaderLabel(title, systemImage: systemImage, tint: tint)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
            // Pinned tabs are closable too — the hover ✕ works regardless of pin state.
            onClose: { closeTabAction(tab) }
        )
        .opacity(isHib ? 0.55 : 1.0)
        .overlay(alignment: .trailing) {
            // Status indicators (mute / pin / hibernate) share the trailing edge with the row's close (✕)
            // button. Hide them whenever the ✕ is visible (on hover or while selected) so they neither
            // overlap nor swallow the click — that was why a pinned tab's ✕ did nothing. They're also
            // purely decorative, so never hit-testable.
            let showsCloseButton = selectedTabID == tab.id || hoveredTabID == tab.id
            if !showsCloseButton {
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
                .allowsHitTesting(false)
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
            VStack(spacing: 5) {
                ForEach(pinnedTabs) { tab in
                    collapsedTabRow(for: tab)
                }

                if !pinnedTabs.isEmpty && !regularTabs.isEmpty {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(AdaptiveChrome.divider(colorScheme))
                        .frame(width: 22, height: 1)
                        .padding(.vertical, 2)
                }

                ForEach(regularTabs) { tab in
                    collapsedTabRow(for: tab)
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 6)
    }

    /// One collapsed-rail entry: the tab tile centered in the rail with a leading accent bar that marks
    /// the active tab (VS Code / Xcode-navigator style). The bar animates in and out as selection moves.
    @ViewBuilder
    private func collapsedTabRow(for tab: BrowserTab) -> some View {
        let isSelected = selectedTabID == tab.id
        collapsedTabIcon(for: tab)
            .frame(maxWidth: .infinity)   // center the tile in the rail; the bar hugs the leading edge
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 3, height: 20)
                    .opacity(isSelected ? 1 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
            }
    }

    /// Fill for a collapsed tab tile across its three states (selected / hovered / idle).
    private func collapsedTileFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return AdaptiveChrome.fill(colorScheme, dark: 0.14) }
        if isHovered { return AdaptiveChrome.fill(colorScheme, dark: 0.08) }
        return AdaptiveChrome.fill(colorScheme, dark: 0.035)
    }

    /// A small circular status badge (pin / mute / onion / hibernate) drawn in a tile corner.
    private func collapsedCornerBadge(systemName: String, size: CGFloat, background: Color, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .padding(2)
            .background(background, in: Circle())
    }

    @ViewBuilder
    private func collapsedTabIcon(for tab: BrowserTab) -> some View {
        let isSelected = selectedTabID == tab.id
        let isHovered = hoveredTabID == tab.id
        let isHib = TabHibernationManager.shared.isHibernated(tab)
        // On hover the close (✕) claims the top-right corner, so the top-right status badges step aside.
        let showsClose = isHovered

        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(collapsedTileFill(isSelected: isSelected, isHovered: isHovered))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected ? AdaptiveChrome.border(colorScheme, dark: 0.20) : Color.clear,
                            lineWidth: 1
                        )
                )
                .frame(width: 38, height: 38)
                .opacity(isHib ? 0.6 : 1.0)

            if tab.kind.isUtility {
                Image(systemName: tab.kind.utilityIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .opacity(isHib ? 0.5 : 1.0)
            } else {
                FaviconView(
                    pageURL: tab.pageURLString,
                    size: 19,
                    cornerRadius: 5,
                    loadRemote: !tab.isPrivate
                )
                .opacity(isHib ? 0.5 : 1.0)
            }

            // Top-left: pin (persistent — pinning also groups the tab).
            if tab.isPinned {
                collapsedCornerBadge(systemName: "pin.fill", size: 6.5,
                                     background: Color.black.opacity(0.6), tint: Color.white.opacity(0.9))
                    .offset(x: -13, y: -13)
            }

            // Top-right cluster: privacy / onion / hibernate — hidden while the ✕ occupies that corner.
            if !showsClose {
                if tab.isPrivate {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                        .offset(x: 13, y: -13)
                } else if tab.privacyMode == .onion {
                    collapsedCornerBadge(systemName: "point.3.connected.trianglepath.dotted", size: 7,
                                         background: Color.black.opacity(0.6), tint: Color.white)
                        .offset(x: 13, y: -13)
                } else if isHib {
                    collapsedCornerBadge(systemName: "moon.zzz.fill", size: 7,
                                         background: Color.black.opacity(0.35), tint: Color.white.opacity(0.75))
                        .offset(x: 13, y: -13)
                }
            }

            // Bottom-right: mute (persistent).
            if tab.isMuted {
                collapsedCornerBadge(systemName: "speaker.slash.fill", size: 6.5,
                                     background: Color.gray.opacity(0.7), tint: Color.white.opacity(0.85))
                    .offset(x: 13, y: 13)
            }

            // Hover ✕ — close a tab straight from the rail without expanding first. A real Button sits on
            // top of the tap area; the tile's simultaneous tap (below) still selects everywhere else.
            if showsClose {
                Button {
                    closeTabAction(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color.black.opacity(0.62)))
                }
                .buttonStyle(.plain)
                .offset(x: 13, y: -13)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 38, height: 38)
        .scaleEffect(isSelected || isHovered ? 1.0 : 0.965)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Simultaneous (not exclusive) tap so it coexists with the hover ✕ Button on top — same reason
        // TabButton uses a simultaneous gesture for its rows.
        .simultaneousGesture(TapGesture().onEnded { selectedTabID = tab.id })
        .onHover { hovering in
            DispatchQueue.main.async { hoveredTabID = hovering ? tab.id : nil }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: isSelected)
        .animation(.spring(response: 0.26, dampingFraction: 0.85), value: isHovered)
        .contextMenu { tabContextMenu(for: tab) }
        .help(tab.title.isEmpty ? "New Tab" : tab.title)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func tabContextMenu(for tab: BrowserTab) -> some View {
        if tab.kind == .web {
            Button {
                bookmarkTabAction(tab)
            } label: {
                Label("Bookmark Tab", systemImage: "bookmark")
            }
            .disabled(tab.currentURL == nil && tab.webView?.url == nil)
        }

        Button {
            pinTabAction(tab)
        } label: {
            Label(
                tab.isPinned ? "Unpin Tab" : "Pin Tab",
                systemImage: tab.isPinned ? "pin.slash" : "pin"
            )
        }

        // Move to a user-created category (normal web tabs only — onion/utility tabs live in fixed groups).
        if tab.kind == .web && tab.privacyMode != .onion {
            moveToCategoryMenu(for: tab)
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

        // Pinned tabs are closable — pinning protects against nothing here, it only groups the tab.
        Button(role: .destructive) {
            closeTabAction(tab)
        } label: {
            Label(Localization.string("close_tab"), systemImage: "xmark")
        }
    }

    /// Submenu listing the user's categories so a tab can be moved into one (or back to "Tabs"), plus a
    /// shortcut to create a new category (which the tab is then moved into).
    @ViewBuilder
    private func moveToCategoryMenu(for tab: BrowserTab) -> some View {
        Menu {
            Button {
                moveTabToCategory(tab, nil)
            } label: {
                Label("Tabs (no category)", systemImage: tab.categoryID == nil ? "checkmark" : "tray")
            }

            if !customCategories.isEmpty { Divider() }

            ForEach(customCategories) { category in
                Button {
                    moveTabToCategory(tab, category.id)
                } label: {
                    Label(category.name, systemImage: tab.categoryID == category.id ? "checkmark" : category.systemImage)
                }
            }

            if canAddCategory {
                Divider()
                Button {
                    beginCreateCategory(moving: tab)
                } label: {
                    Label("New Category…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Label("Move to Category", systemImage: "folder")
        }
    }

    // MARK: - Top zone

    private var topNavigationZone: some View {
        Group {
            if isCollapsed {
                VStack(spacing: 6) {
                    // Primary action: New Tab gets a filled, prominent tile.
                    collapsedRailButton(
                        systemName: "plus",
                        help: Localization.string("new_tab"),
                        prominent: true,
                        action: newTabAction
                    )

                    // New Private Tab — mirrors the expanded header (hidden when tabs open private already).
                    if !PrivacyManager.shared.defaultNewTabsToPrivate {
                        collapsedRailButton(
                            systemName: "shield.fill",
                            help: "New Private Tab",
                            prominent: false,
                            action: newPrivateTabAction
                        )
                    }

                    // Reopen the last closed tab, when there is one.
                    if hasClosedTabs, let reopen = reopenClosedTabAction {
                        collapsedRailButton(
                            systemName: "arrow.uturn.backward",
                            help: "Reopen Last Closed Tab",
                            prominent: false,
                            action: reopen
                        )
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }

                    // Expand back to the full sidebar (also ⌘S).
                    collapsedRailButton(
                        systemName: "chevron.right",
                        help: "Expand Sidebar (⌘S)",
                        prominent: false,
                        action: toggleCollapse
                    )

                    Rectangle()
                        .fill(AdaptiveChrome.divider(colorScheme))
                        .frame(width: 26, height: 1)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hasClosedTabs)
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
                                .foregroundStyle(.primary)
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

    /// A control in the collapsed rail's top zone. `prominent` gives the primary New Tab action a larger,
    /// bordered tile; the rest are quieter. All light up on hover.
    private func collapsedRailButton(
        systemName: String,
        help: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRailControl == systemName
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 14 : 12, weight: .semibold))
                .foregroundStyle(prominent ? .primary : .secondary)
                .frame(width: 38, height: prominent ? 38 : 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AdaptiveChrome.fill(
                            colorScheme,
                            dark: prominent ? (isHovered ? 0.16 : 0.12) : (isHovered ? 0.09 : 0.045)
                        ))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    prominent ? AdaptiveChrome.border(colorScheme, dark: 0.16) : Color.clear,
                                    lineWidth: prominent ? 1 : 0
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            DispatchQueue.main.async {
                if hovering { hoveredRailControl = systemName }
                else if hoveredRailControl == systemName { hoveredRailControl = nil }
            }
        }
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
                Text("v\(Bundle.main.appVersion)")
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
