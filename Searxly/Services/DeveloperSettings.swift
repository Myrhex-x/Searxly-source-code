//
//  DeveloperSettings.swift
//  Searxly
//
//  Centralized settings for Developer Mode.
//  Focused on testing aids and debugging tools.
//

import Foundation
import SwiftUI
import Darwin.Mach  // For mach_task_basic_info and task_info

@MainActor
@Observable
final class DeveloperSettings {
    static let shared = DeveloperSettings()

    // MARK: - Core Toggle
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "developerModeEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "developerModeEnabled")
            // Notify listeners that developer mode state changed
            NotificationCenter.default.post(name: .developerModeDidChange, object: nil)
        }
    }

    // MARK: - Testing Aids

    /// When true, all spring/animation durations are drastically reduced or disabled.
    /// Extremely useful when developing or testing UI changes.
    var disableAnimations: Bool {
        get { UserDefaults.standard.bool(forKey: "developerDisableAnimations") }
        set { UserDefaults.standard.set(newValue, forKey: "developerDisableAnimations") }
    }

    /// Shows a small performance overlay with approximate FPS.
    var showPerformanceOverlay: Bool {
        get { UserDefaults.standard.bool(forKey: "developerShowPerformanceOverlay") }
        set { UserDefaults.standard.set(newValue, forKey: "developerShowPerformanceOverlay") }
    }

    /// Forces every new tab to be created in Standard mode, ignoring the privacy default.
    var forceStandardTabs: Bool {
        get { UserDefaults.standard.bool(forKey: "developerForceStandardTabs") }
        set { UserDefaults.standard.set(newValue, forKey: "developerForceStandardTabs") }
    }

    /// Prevents automatic tab hibernation from ever running.
    var disableAutoHibernation: Bool {
        get { UserDefaults.standard.bool(forKey: "developerDisableAutoHibernation") }
        set { UserDefaults.standard.set(newValue, forKey: "developerDisableAutoHibernation") }
    }

    // MARK: - Logging

    var verboseSearXNGLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "developerVerboseSearXNG") }
        set { UserDefaults.standard.set(newValue, forKey: "developerVerboseSearXNG") }
    }

    var verboseTabLifecycleLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "developerVerboseTabLifecycle") }
        set { UserDefaults.standard.set(newValue, forKey: "developerVerboseTabLifecycle") }
    }

    /// When enabled, App Lock, encryption, and other security-related operations log more details.
    /// Recommended off for normal private use (even in debug builds) to reduce console noise.
    var verboseSecurityLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "developerVerboseSecurityLogging") }
        set { UserDefaults.standard.set(newValue, forKey: "developerVerboseSecurityLogging") }
    }

    // MARK: - WebKit Debugging

    /// When enabled, Web Inspector (right-click → Inspect Element) becomes available.
    var webInspectorEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "developerWebInspectorEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "developerWebInspectorEnabled")
            NotificationCenter.default.post(name: .developerWebInspectorSettingChanged, object: nil)
        }
    }

    /// When true, completely bypasses our adblock scripts, rule lists, and layout fixes for any
    /// youtube.com / youtu.be navigation. This is the nuclear "make YouTube videos work no matter what"
    /// option. The native recovery code still runs to try to clean up YouTube's own enforcement UI.
    var youTubeCompatibilityMode: Bool {
        get { UserDefaults.standard.bool(forKey: "developerYouTubeCompatibilityMode") }
        set { UserDefaults.standard.set(newValue, forKey: "developerYouTubeCompatibilityMode") }
    }

    // VPN is disabled in the current build (per user request).
    // - The real Packet Tunnel extension target + WireGuardKit (extension only) + paid team
    //   provisioning is not set up. All UI entry points (pills, Settings > VPN, browser controls)
    //   are gated off. Source + IMPLEMENTATION_NOTES are preserved for later.
    // The integrated wallet system has been completely removed.

    // MARK: - Helpers

    /// Returns an animation that is either the provided one or a very fast/no-op animation
    /// when "Disable animations" is turned on in Developer Mode. Great for UI testing.
    static func animation(_ animation: Animation) -> Animation {
        if shared.isEnabled && shared.disableAnimations {
            return .linear(duration: 0.01)
        }
        return animation
    }

    /// Returns current app memory usage in MB (resident size).
    static func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0
        }
        return 0
    }

    private init() {}
}

// Notification names
extension Notification.Name {
    static let developerModeDidChange = Notification.Name("Searxly.DeveloperModeDidChange")
    static let developerWebInspectorSettingChanged = Notification.Name("Searxly.DeveloperWebInspectorSettingChanged")
}