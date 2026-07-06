//
//  PerSiteSettings.swift
//  SearxlyiOS
//
//  Remembered per-host page preferences (Safari's per-site settings): Request Desktop Website
//  and text zoom, applied automatically on every navigation to that host. Stored ENCRYPTED
//  (SitePrefs.enc) because a host list is browsing history, even without timestamps.
//

import Foundation
import Observation

struct SiteSettings: Codable, Equatable {
    var desktopMode: Bool?
    var textZoom: Double?

    var isEmpty: Bool { desktopMode == nil && textZoom == nil }
}

@MainActor
@Observable
final class PerSiteSettings {
    static let shared = PerSiteSettings()

    private static let file = SecureLibraryStorage.fileURL(name: "SitePrefs.enc")
    private var map: [String: SiteSettings]

    private init() {
        map = SecureLibraryStorage.load([String: SiteSettings].self, from: Self.file) ?? [:]
    }

    func settings(forHost host: String?) -> SiteSettings {
        guard let key = ShieldSettings.normalizedHost(host) else { return SiteSettings() }
        return map[key] ?? SiteSettings()
    }

    func setDesktopMode(_ on: Bool, forHost host: String?) {
        update(host) { $0.desktopMode = on ? true : nil }  // mobile is the default → store only the exception
    }

    func setTextZoom(_ zoom: Double, forHost host: String?) {
        update(host) { $0.textZoom = abs(zoom - 1.0) < 0.01 ? nil : zoom }
    }

    func clearAll() {
        map = [:]
        SecureLibraryStorage.erase(url: Self.file)
    }

    private func update(_ host: String?, _ mutate: (inout SiteSettings) -> Void) {
        guard let key = ShieldSettings.normalizedHost(host) else { return }
        var entry = map[key] ?? SiteSettings()
        mutate(&entry)
        if entry.isEmpty { map.removeValue(forKey: key) } else { map[key] = entry }
        SecureLibraryStorage.save(map, to: Self.file)
    }
}
