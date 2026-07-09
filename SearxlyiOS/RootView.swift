//
//  RootView.swift
//  SearxlyiOS
//
//  Root of the iOS app. Hosts the Phase 1 browser shell, gated by the optional App Lock:
//  an opaque monochrome shield covers content whenever the scene isn't active (so the app-switcher
//  snapshot never leaks a page), and Face ID / passcode is required to return when locked.
//

import SwiftUI
import WidgetKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    private var appLock = AppLockManager.shared

    var body: some View {
        ZStack {
            BrowserView()

            if appLock.isEnabled && (appLock.isLocked || scenePhase != .active) {
                LockShieldView(showUnlock: appLock.isLocked && scenePhase == .active)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: appLock.isLocked)
        // Searxly is strictly monochrome — override the system blue/green accent everywhere
        // (toggles, links, selection) with the adaptive black/white brand color.
        .tint(Brand.text)
        // Ready the on-device Apple Intelligence model — but a couple of seconds AFTER launch, so
        // prewarming the model doesn't compete with first paint / tab restore (it was slowing launch).
        .task {
            try? await Task.sleep(for: .seconds(2))
            PageIntelligence.prewarm()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                AppLockManager.shared.lock()
                // Coalesced once-per-background: refresh the "trackers blocked" Home Screen widget.
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

/// Opaque cover: brand wordmark + unlock affordance. Also serves as the app-switcher snapshot.
private struct LockShieldView: View {
    let showUnlock: Bool
    @State private var promptedOnce = false

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .scaledFont(size: 30, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                    Text("Searxly")
                        .scaledFont(size: 26, weight: .semibold)
                        .foregroundStyle(Brand.text)
                }

                if showUnlock {
                    Button {
                        Task { await AppLockManager.shared.unlock() }
                    } label: {
                        Text("Unlock with \(AppLockManager.shared.biometryLabel)")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(Brand.bg)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 11)
                            .background(Brand.text, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: showUnlock) {
            // Auto-prompt the first time the shield is interactive; after a failure the
            // user retries via the button (no prompt loops).
            if showUnlock && !promptedOnce {
                promptedOnce = true
                await AppLockManager.shared.unlock()
            }
        }
    }
}

#Preview {
    RootView()
}
