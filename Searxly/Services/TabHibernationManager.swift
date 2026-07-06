//
//  TabHibernationManager.swift
//  Searxly
//
//  Dedicated manager responsible for deciding when and how to hibernate
//  background tabs in order to reduce memory usage.
//
//  This is intentionally separate from BrowserTab and ContentView so the
//  hibernation policy can evolve independently (max tabs, delay, strategy, etc.)
//  without polluting the core tab or UI code.
//

import Foundation
import os
import SwiftUI
import WebKit

extension Notification.Name {
    static let tabHibernationAutoSweepDue = Notification.Name("TabHibernationAutoSweepDue")
    /// Posted when the OS signals memory pressure. ContentView responds by hibernating background tabs
    /// (it owns the tab list). userInfo["critical"] = true for .critical events.
    static let tabHibernationMemoryPressureDue = Notification.Name("TabHibernationMemoryPressureDue")
}

/// Lightweight snapshot of tab state, useful for developer tooling.
struct TabStats: Equatable {
    var total: Int = 0
    var active: Int = 0          // not hibernated
    var hibernated: Int = 0
}

@MainActor
@Observable
final class TabHibernationManager {
    static let shared = TabHibernationManager()

    // MARK: - Configuration (can later be driven by Settings)

    /// Whether tab hibernation is enabled at all.
    /// When false, wakeUp/ hibernate calls are no-ops.
    /// Also respects DeveloperSettings.disableAutoHibernation.
    var isEnabled: Bool {
        get {
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.disableAutoHibernation {
                return false
            }
            return _isEnabled
        }
        set {
            let oldValue = _isEnabled
            _isEnabled = newValue
            if _isEnabled != oldValue {
                saveConfiguration()
                if isEnabled {
                    if autoSweepTimer == nil {
                        startAutoSweepTimer()
                    }
                } else {
                    autoSweepTimer?.invalidate()
                    autoSweepTimer = nil
                    secondsUntilNextAutoSweep = Int(inactivityTimeout)
                }
            }
        }
    }

    private var _isEnabled: Bool = true

    /// Maximum number of tabs that should remain fully loaded at once.
    /// Older background tabs will be hibernated first.
    var maxActiveTabs: Int = 8 {
        didSet {
            if maxActiveTabs != oldValue {
                saveConfiguration()
            }
        }
    }

    /// How long (in seconds) a background tab can stay loaded before we consider
    /// hibernating it when we're over the maxActiveTabs limit.
    var hibernationDelay: TimeInterval = 30

    /// Inactivity timeout in seconds. Tabs that haven't been selected for this long
    /// will be automatically hibernated (independent of maxActiveTabs).
    /// Default: 10 minutes.
    var inactivityTimeout: TimeInterval = 600 {  // 10 minutes default
        didSet {
            if inactivityTimeout != oldValue {
                saveConfiguration()
            }
            if isEnabled {
                lastSweepDate = Date()
                secondsUntilNextAutoSweep = Int(inactivityTimeout)
            }
        }
    }

    // MARK: - Runtime State

    private var lastAccessTimes: [UUID: Date] = [:]

    /// Latest computed tab statistics. Updated by ContentView when tabs change.
    private(set) var stats: TabStats = TabStats()

    /// For UI: live countdown (in seconds) until the next automatic inactivity sweep.
    private(set) var secondsUntilNextAutoSweep: Int = 600

    private var autoSweepTimer: Timer?
    private var lastSweepDate: Date = Date()

    /// OS memory-pressure monitor. On warning/critical we purge image caches and ask the UI to
    /// hibernate background tabs, so the app reclaims memory before the system kills it.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        loadConfiguration()
        startAutoSweepTimer()
        startMemoryPressureMonitor()
    }

    /// Loads hibernation policy from AppData.json (called on init so settings survive restart).
    func loadConfiguration() {
        let data = Persistence.load()
        _isEnabled = data.tabHibernationEnabled
        maxActiveTabs = data.tabHibernationMaxActiveTabs
        inactivityTimeout = TimeInterval(data.tabHibernationInactivityTimeout)
    }

    /// Persists current hibernation policy to AppData.json.
    func saveConfiguration() {
        var current = Persistence.load()
        current.tabHibernationEnabled = _isEnabled
        current.tabHibernationMaxActiveTabs = maxActiveTabs
        current.tabHibernationInactivityTimeout = Int(inactivityTimeout)
        Persistence.save(current)
    }

    // MARK: - Public API

    /// Call this whenever a tab becomes the active/selected tab.
    /// It marks the tab as recently used and can trigger hibernation of others.
    func didSelectTab(_ tab: BrowserTab, amongAllTabs tabs: [BrowserTab]) {
        guard isEnabled else { return }

        lastAccessTimes[tab.id] = Date()

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseTabLifecycleLogging {
            Log.web.info("[Dev] Tab selected: \(tab.title) (hibernated: \(tab.isHibernated))")
        }

        // Special non-web tabs (e.g. passwords vault) never participate in hibernation.
        guard tab.kind == .web else { return }

        // Wake up the newly selected tab if it was hibernated
        if tab.isHibernated {
            tab.wakeUp()
        }

        // NOTE: We intentionally do NOT opportunistically hibernate here.
        // Automatic hibernation is driven purely by the global countdown timer
        // (see performInactivityBasedHibernation + the sweep).
        // This keeps the behavior "global" rather than per-tab-switch.
    }

    /// Called after a tab is manually or automatically woken up.
    func didWakeTab(_ tab: BrowserTab) {
        lastAccessTimes[tab.id] = Date()

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseTabLifecycleLogging {
            Log.web.info("[Dev] Woke up tab: \(tab.title)")
        }
    }

    /// Explicitly hibernate a single tab (e.g. from UI or when closing other tabs).
    func hibernateTab(_ tab: BrowserTab) {
        guard isEnabled, !tab.isHibernated else { return }
        tab.hibernate()

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseTabLifecycleLogging {
            Log.web.info("[Dev] Hibernated tab: \(tab.title)")
        }
    }

    /// Hibernate as many background tabs as needed to stay under maxActiveTabs.
    /// Prefers hibernating the least recently used tabs.
    ///
    /// The "+1" accounts for the current tab (which we never hibernate here).
    /// Example: 12 background tabs active + 1 current = 13 total active.
    /// With maxActiveTabs=8 we need to hibernate 13-8 = 5 of the oldest background ones.
    private func hibernateOldBackgroundTabs(except currentTab: BrowserTab?, among tabs: [BrowserTab]) {
        guard isEnabled else { return }

        let activeBackground = tabs.filter { !$0.isHibernated && $0.id != currentTab?.id }
        let allowedBackground = max(0, maxActiveTabs - 1)   // current tab always gets one slot
        guard activeBackground.count > allowedBackground else { return }

        // Sort by last access time (oldest first)
        let sortedByAge = activeBackground.sorted { lhs, rhs in
            let lhsTime = lastAccessTimes[lhs.id] ?? .distantPast
            let rhsTime = lastAccessTimes[rhs.id] ?? .distantPast
            return lhsTime < rhsTime
        }

        let excess = activeBackground.count - allowedBackground
        let toHibernate = sortedByAge.prefix(excess)

        for tab in toHibernate {
            hibernateTab(tab)
        }
    }

    /// Call this on app backgrounding or periodically if you want aggressive hibernation.
    func hibernateAllBackgroundTabs(except currentTab: BrowserTab?, among tabs: [BrowserTab]) {
        guard isEnabled else { return }

        for tab in tabs where tab.id != currentTab?.id && tab.kind == .web {
            hibernateTab(tab)
        }

        currentStats(among: tabs)
    }

    /// Restores all hibernated tabs (useful for "wake everything" or before session save).
    func wakeAllHibernatedTabs(in tabs: [BrowserTab]) {
        for tab in tabs where tab.isHibernated {
            tab.wakeUp()
            didWakeTab(tab)   // properly updates last access time
        }
        currentStats(among: tabs)
    }

    /// Returns whether the given tab is currently hibernated.
    /// This is the source of truth (stored directly on the tab).
    func isHibernated(_ tab: BrowserTab) -> Bool {
        tab.isHibernated
    }

    /// Public read-only access to the last time a tab was selected or woken up.
    /// Used by TabCleanupManager for time-based auto-close decisions.
    func lastAccessTime(for tab: BrowserTab) -> Date? {
        lastAccessTimes[tab.id]
    }

    /// Internal for the cleanup manager (same-module access)
    func lastAccessTime(forTabID id: UUID) -> Date? {
        lastAccessTimes[id]
    }

    /// Computes current tab statistics. Pass in the full tabs array from BrowserState (via ContentView).
    @discardableResult
    func currentStats(among tabs: [BrowserTab]) -> TabStats {
        var newStats = TabStats()
        newStats.total = tabs.count

        for tab in tabs {
            if tab.isHibernated {
                newStats.hibernated += 1
            } else {
                newStats.active += 1
            }
        }
        self.stats = newStats
        return newStats
    }

    // MARK: - Automatic Time-Based Hibernation Timer

    private func startAutoSweepTimer() {
        autoSweepTimer?.invalidate()

        // Tick every 5 seconds — accurate enough for the displayed countdown and
        // for the hibernation sweep, while avoiding the battery cost of 1 Hz on laptops.
        autoSweepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickAutoSweepTimer()
            }
        }
    }

    // MARK: - Memory pressure

    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let data = self.memoryPressureSource?.data else { return }
            self.handleMemoryPressure(critical: data.contains(.critical))
        }
        memoryPressureSource = source
        source.resume()
    }

    private func handleMemoryPressure(critical: Bool) {
        // Always reclaim image memory — it's cheap and reloads on demand. Drop the disk cache too when critical.
        SearchThumbnailLoader.purgeCaches(includingDisk: critical)

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseTabLifecycleLogging {
            Log.web.info("[Dev] Memory pressure (\(critical ? "critical" : "warning")) — purged image caches, requesting background-tab hibernation")
        }

        // The UI layer owns the tab list, so ask it to hibernate background tabs (respects isEnabled there).
        NotificationCenter.default.post(name: .tabHibernationMemoryPressureDue, object: nil,
                                        userInfo: ["critical": critical])
    }

    /// Stops the repeating sweep timer while the app is in the background, so it doesn't wake the CPU
    /// on battery. `lastSweepDate` is preserved, so background-idle time still counts toward the next
    /// sweep once the app is active again (see tickAutoSweepTimer's elapsed-since-lastSweep math).
    /// Memory-pressure reclaim is unaffected — that source fires regardless of this timer.
    func suspendAutoSweep() {
        autoSweepTimer?.invalidate()
        autoSweepTimer = nil
    }

    /// Restarts the sweep timer when the app becomes active again (no-op if disabled or already running).
    func resumeAutoSweep() {
        guard isEnabled, autoSweepTimer == nil else { return }
        startAutoSweepTimer()
    }

    private func tickAutoSweepTimer() {
        guard isEnabled else {
            secondsUntilNextAutoSweep = Int(inactivityTimeout)
            return
        }

        let now = Date()
        let elapsedSinceLastSweep = now.timeIntervalSince(lastSweepDate)
        let remaining = max(0, inactivityTimeout - elapsedSinceLastSweep)

        secondsUntilNextAutoSweep = Int(remaining)

        // Time for a sweep? Use a 5-second grace window to account for the coarser tick interval.
        if remaining <= 5 {
            performAutomaticInactivitySweep()
            lastSweepDate = now
            secondsUntilNextAutoSweep = Int(inactivityTimeout)
        }
    }

    private func performAutomaticInactivitySweep() {
        // This will be called from the timer. We need the full list of tabs,
        // so the actual sweep logic lives in ContentView which calls back into the manager.
        // Here we just notify that a sweep is due.
        NotificationCenter.default.post(name: .tabHibernationAutoSweepDue, object: nil)
    }

    /// Called by ContentView during the automatic sweep.
    /// This is the **global** mechanism:
    /// 1. Hibernates background tabs idle longer than `inactivityTimeout`.
    /// 2. Then (if still over the limit) enforces `maxActiveTabs` using LRU.
    ///
    /// All automatic hibernation is driven by the single global countdown timer.
    func performInactivityBasedHibernation(currentTab: BrowserTab?, among tabs: [BrowserTab]) {
        guard isEnabled else { return }
        // (web-only filtering applied at call sites and inside loops for special-tab exclusion)

        let cutoff = Date().addingTimeInterval(-inactivityTimeout)

        // 1. Inactivity-based (global timer driven)
        for tab in tabs where tab.id != currentTab?.id && tab.kind == .web {
            let lastAccess = lastAccessTimes[tab.id] ?? .distantPast
            if lastAccess < cutoff && !tab.isHibernated {
                hibernateTab(tab)
            }
        }

        // 2. Enforce hard cap on number of active tabs (still under the global sweep)
        hibernateOldBackgroundTabs(except: currentTab, among: tabs)

        // Ensure UI stats are fresh after the sweep
        currentStats(among: tabs)
    }
}