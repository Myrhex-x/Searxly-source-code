//
//  PrivacyDisclosures.swift
//  Searxly
//
//  One-shot privacy disclosures. Some conveniences (bang shortcuts, knowledge panel) send
//  data to third parties by design; the first time each one fires we tell the user plainly,
//  once, via the in-app toast. The shown-flags are not sensitive, so UserDefaults is fine.
//

import Foundation
import os

@MainActor
enum PrivacyDisclosures {

    enum DisclosureID: String {
        case bangShortcuts = "bangShortcuts"
        case knowledgePanel = "knowledgePanel"
    }

    private static func flagKey(_ id: DisclosureID) -> String { "privacyDisclosureShown.\(id.rawValue)" }

    /// Shows the given disclosure the first time it's requested; subsequent calls are no-ops.
    static func showOnce(_ id: DisclosureID, title: String, body: String, iconSystemName: String = "eye.trianglebadge.exclamationmark") {
        let key = flagKey(id)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NotificationManager.shared.showInApp(
            title: title,
            body: body,
            source: "Privacy",
            iconSystemName: iconSystemName
        )
        Log.privacy.info("PrivacyDisclosures: showed one-time disclosure \(id.rawValue, privacy: .public)")
    }
}
