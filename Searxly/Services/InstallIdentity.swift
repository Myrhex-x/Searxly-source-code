//
//  InstallIdentity.swift
//  Searxly
//
//  Stable per-install identifier (device-local, non-secret). Used by the VPN control plane to
//  dedupe one grant per device. This previously lived on the now-removed SearxlyAIIdentity; the
//  UserDefaults key is preserved so existing installs keep the same id.
//

import Foundation

enum InstallIdentity {
    private nonisolated static let clientKey = "SearxlyAI.clientId.v1"

    /// Stable per-install id, created on first read and persisted in UserDefaults.
    nonisolated static var clientID: String {
        if let existing = UserDefaults.standard.string(forKey: clientKey) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clientKey)
        return id
    }
}
