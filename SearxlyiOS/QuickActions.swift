//
//  QuickActions.swift
//  SearxlyiOS
//
//  Home-screen icon long-press → Quick Actions (New Search / New Private Tab / Reopen Last Tab).
//  SwiftUI has no first-class hook for `UIApplicationShortcutItem`, so a tiny app + scene delegate
//  catch the item — cold launch via `connectionOptions.shortcutItem`, warm via `performActionFor` —
//  and hand it to the live browser through `IntentRouter`, the same on-device channel Siri and
//  Spotlight use. Nothing here touches the network.
//

import UIKit

/// The three home-screen quick actions, each mapped to an `IntentRouter` hand-off.
enum QuickAction: String {
    case newSearch     = "com.myrhex.searxly.newSearch"
    case newPrivateTab = "com.myrhex.searxly.newPrivateTab"
    case reopenLast    = "com.myrhex.searxly.reopenLast"

    private var title: String {
        switch self {
        case .newSearch:     return NSLocalizedString("New Search", comment: "Quick action")
        case .newPrivateTab: return NSLocalizedString("New Private Tab", comment: "Quick action")
        case .reopenLast:    return NSLocalizedString("Reopen Last Tab", comment: "Quick action")
        }
    }

    private var symbol: String {
        switch self {
        case .newSearch:     return "magnifyingglass"
        case .newPrivateTab: return "hand.raised"
        case .reopenLast:    return "arrow.uturn.left"
        }
    }

    var item: UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: rawValue,
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: symbol),
            userInfo: nil
        )
    }

    /// Hands the action to the running browser. The browser drains `IntentRouter` on next update.
    func route() {
        switch self {
        case .newSearch:     IntentRouter.shared.pendingNewSearch = true
        case .newPrivateTab: IntentRouter.shared.pendingPrivateTab = true
        case .reopenLast:    IntentRouter.shared.pendingReopenLast = true
        }
    }
}

enum QuickActions {
    /// Installs the long-press menu (top-to-bottom = declared order).
    static func register() {
        UIApplication.shared.shortcutItems = [
            QuickAction.newSearch.item,
            QuickAction.newPrivateTab.item,
            QuickAction.reopenLast.item,
        ]
    }

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type) else { return false }
        action.route()
        return true
    }
}

/// Minimal app delegate: registers the quick actions and attaches a scene delegate to catch them.
/// Adopted by `SearxlyiOSApp` via `@UIApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        QuickActions.register()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

/// Its only job is to forward a quick action to `IntentRouter`. It deliberately does NOT create a
/// window — SwiftUI's `WindowGroup` still owns the UI and drives `scenePhase` (the App Lock shield).
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Cold launch straight into a quick action: stash it; the browser drains it on first appear.
        if let item = connectionOptions.shortcutItem { QuickActions.perform(item) }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActions.perform(shortcutItem))
    }
}
