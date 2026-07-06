//
//  SitePermissionStore.swift
//  Searxly
//
//  Per-site permission decisions (camera, microphone) that the user controls from the address-bar
//  privacy popover. Enforced in the WKUIDelegate media-capture callback (WebViewRepresentable+
//  Navigation). Default for every site is `.ask` — Searxly does nothing until the user explicitly
//  Allows or Blocks a site, so out-of-the-box behavior matches WebKit's own prompt.
//
//  These are preferences, not secrets, so they live in UserDefaults (a small host→decision table).
//

import Foundation

enum SitePermission: String, Codable, CaseIterable {
    case camera
    case microphone

    var label: String {
        switch self {
        case .camera:     return "Camera"
        case .microphone: return "Microphone"
        }
    }

    var systemImage: String {
        switch self {
        case .camera:     return "camera.fill"
        case .microphone: return "mic.fill"
        }
    }
}

enum SitePermissionDecision: String, Codable, CaseIterable {
    case ask
    case allow
    case block

    var label: String {
        switch self {
        case .ask:   return "Ask"
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }
}

@MainActor
@Observable
final class SitePermissionStore {
    static let shared = SitePermissionStore()

    private let defaultsKey = "Searxly.SitePermissions.v1"
    /// host → (permission.rawValue → decision.rawValue). Only non-`.ask` decisions are stored.
    private var table: [String: [String: String]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            table = decoded
        } else {
            table = [:]
        }
    }

    /// The user's decision for a permission on a host (`.ask` when nothing is stored).
    func decision(_ permission: SitePermission, for host: String) -> SitePermissionDecision {
        guard let raw = table[host.lowercased()]?[permission.rawValue],
              let decision = SitePermissionDecision(rawValue: raw) else {
            return .ask
        }
        return decision
    }

    func set(_ decision: SitePermissionDecision, _ permission: SitePermission, for host: String) {
        let key = host.lowercased()
        var perHost = table[key] ?? [:]
        if decision == .ask {
            perHost[permission.rawValue] = nil   // back to default — don't persist the row
        } else {
            perHost[permission.rawValue] = decision.rawValue
        }
        if perHost.isEmpty { table[key] = nil } else { table[key] = perHost }
        save()
    }

    /// Forgets all permission overrides for a host (used by "clear this site's data").
    func clear(host: String) {
        table[host.lowercased()] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
