//
//  NotificationManager.swift
//  Searxly
//
//  Custom in-app + system notification system.
//  - In-app toasts (liquid glass, fluid, stacked) only when actively viewing web content (showingWebContent).
//  - Falls back to standard macOS notifications (UNUserNotificationCenter) otherwise.
//  - Designed to be split across files (service + models + multiple component views) to avoid monolithic changes.
//  - Testable from Developer settings.
//

import Foundation
import os
import SwiftUI
@preconcurrency import UserNotifications
import AppKit   // For NSApp.isActive checks

@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    // Currently visible in-app notifications (newest last; presentation layer reverses or stacks as desired).
    private(set) var inAppNotifications: [AppNotification] = []

    // Updated by ContentView when the browser/web content pane becomes visible or hidden.
    // This drives the "only if they're on the browser" decision.
    var isBrowserActive: Bool = false

    private var autoDismissTasks: [UUID: Task<Void, Never>] = [:]

    private init() {
        // Observe app activation changes so we can optionally fall back or suppress.
        // (Simple: if app becomes inactive while browser "active", future shows can decide.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isBrowserActive = false
            }
        }
    }

    // MARK: - Public API

    /// Show a notification.
    /// - If the user is actively "on the browser" (web content visible + app active), show beautiful in-app glass toast.
    /// - Otherwise (search/home, background, etc.), deliver as a regular macOS notification.
    func show(title: String, body: String, source: String = "App", iconSystemName: String = "bell.badge.fill") {
        let notification = AppNotification(
            title: title,
            body: body,
            source: source,
            iconSystemName: iconSystemName
        )

        let shouldShowInApp = isBrowserActive && NSApp.isActive

        if shouldShowInApp {
            // In-app path (fluid glass)
            addInApp(notification)
        } else {
            // Regular macOS notification
            deliverSystemNotification(notification)
        }
    }

    /// Force an in-app toast regardless of current browser state. Used for messages that must
    /// be seen in context (e.g. one-time privacy disclosures) where a macOS notification —
    /// possibly requiring a permission prompt — would be wrong.
    func showInApp(title: String, body: String, source: String = "App", iconSystemName: String = "bell.badge.fill") {
        let notification = AppNotification(
            title: title,
            body: body,
            source: source,
            iconSystemName: iconSystemName
        )
        addInApp(notification)
    }

    /// Force an in-app notification regardless of current browser state.
    /// Useful for developer testing from Settings (so you can trigger the UI from anywhere).
    func showInAppForTest(title: String, body: String, source: String = "X", iconSystemName: String = "at.circle.fill") {
        showInApp(title: title, body: body, source: source, iconSystemName: iconSystemName)
    }

    /// Dismiss a specific in-app notification (user tapped X, swiped, or tapped the card).
    func dismiss(_ id: UUID) {
        autoDismissTasks[id]?.cancel()
        autoDismissTasks[id] = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            inAppNotifications.removeAll { $0.id == id }
        }
    }

    /// Clear all current in-app toasts (e.g. on major navigation change).
    func clearAllInApp() {
        for task in autoDismissTasks.values { task.cancel() }
        autoDismissTasks.removeAll()
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            inAppNotifications.removeAll()
        }
    }

    // MARK: - Internal

    private func addInApp(_ notification: AppNotification) {
        // Keep the stack reasonable (newest on top visually — we insert at end and let presentation VStack decide order).
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            inAppNotifications.append(notification)
            // Cap the number of visible in-app toasts.
            if inAppNotifications.count > 4 {
                let removed = inAppNotifications.removeFirst()
                autoDismissTasks[removed.id]?.cancel()
                autoDismissTasks[removed.id] = nil
            }
        }

        // Schedule auto-dismiss (fluid timeout, typical notification UX ~6-8s).
        scheduleAutoDismiss(for: notification.id, after: 7.0)
    }

    private func scheduleAutoDismiss(for id: UUID, after seconds: TimeInterval) {
        autoDismissTasks[id]?.cancel()

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            if !Task.isCancelled {
                // Only dismiss if it is still present.
                if self.inAppNotifications.contains(where: { $0.id == id }) {
                    self.dismiss(id)
                }
            }
            self.autoDismissTasks[id] = nil
        }
        autoDismissTasks[id] = task
    }

    private func deliverSystemNotification(_ notification: AppNotification) {
        // Request authorization only when we actually need to deliver a system notification.
        // This is non-blocking; the first time the user will see the macOS permission prompt.
        // We re-fetch UNUserNotificationCenter.current() inside the @Sendable completion handlers
        // to avoid capturing the non-Sendable center value (Swift 6 concurrency requirement).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else {
                if let error { Log.app.error("NotificationManager: system notification auth denied: \(error.localizedDescription, privacy: .public)") }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            if !notification.source.isEmpty {
                content.subtitle = notification.source
            }
            content.body = notification.body
            content.sound = .default

            // No category / actions for the basic version (can be extended later for "View" etc).

            let request = UNNotificationRequest(
                identifier: "searxly-\(notification.id.uuidString)",
                content: content,
                trigger: nil   // deliver immediately
            )

            UNUserNotificationCenter.current().add(request) { addError in
                if let addError {
                    Log.app.error("NotificationManager: failed to deliver system notification: \(addError)")
                }
            }
        }
    }
}